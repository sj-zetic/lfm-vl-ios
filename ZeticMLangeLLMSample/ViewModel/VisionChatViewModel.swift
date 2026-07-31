import SwiftUI
import ZeticMLange

@MainActor
final class VisionChatViewModel: ObservableObject {
    enum LoadPhase {
        case downloading
        /// The download callback has reached 1.0 but the model is still being
        /// loaded into memory — otherwise this looks like a bar stuck at 100%.
        case preparing
        case ready
    }

    @Published private(set) var image: UIImage?
    @Published var question: String = Constants.Prompt.defaultQuestion
    @Published private(set) var turns: [VisionTurn] = []

    @Published private(set) var loadPhase: LoadPhase = .downloading
    @Published private(set) var downloadProgress: Float = 0
    @Published private(set) var elapsedSeconds: Int = 0
    @Published private(set) var estimatedSecondsRemaining: Int?
    @Published private(set) var isGenerating = false
    @Published var loadFailure: String?

    /// Disk reclaimed by the janitor, and the container size after it ran.
    @Published private(set) var reclaimedBytes: Int64 = 0
    @Published private(set) var storageUsage: Int64 = 0

    var reclaimedText: String? {
        guard reclaimedBytes > 0 else { return nil }
        return "Reclaimed \(ModelStorageReport.format(reclaimedBytes)) of leftover model files"
    }

    var storageUsageText: String {
        ModelStorageReport.format(storageUsage)
    }

    private let engine = VisionEngine()
    private var generationTask: Task<Void, Never>?

    /// Identifies the current image so the engine knows when context must be cleared.
    private var imageID = UUID()

    private var loadStart: Date?
    private var timerTask: Task<Void, Never>?

    var isModelReady: Bool { loadPhase == .ready }

    var canAsk: Bool {
        isModelReady
            && !isGenerating
            && image != nil
            && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasTranscript: Bool { !turns.isEmpty }

    // MARK: - Model lifecycle

    func loadModel() async {
        guard loadPhase != .ready, loadFailure == nil else { return }
        startLoadClock()
        defer { stopLoadClock() }

        // Before the model is initialised, so nothing being deleted is in use.
        await reclaimStorage()

        do {
            try await engine.load { progress in
                Task { @MainActor [weak self] in
                    self?.recordProgress(progress)
                }
            }
            loadPhase = .ready
        } catch {
            loadFailure = error.localizedDescription
        }
    }

    func retryLoad() {
        loadFailure = nil
        downloadProgress = 0
        loadPhase = .downloading
        estimatedSecondsRemaining = nil
        Task { await loadModel() }
    }

    /// Runs the janitor off the main thread and publishes what it reclaimed.
    private func reclaimStorage() async {
        let result = await Task.detached(priority: .utility) {
            ModelStorageJanitor.reclaim()
        }.value
        reclaimedBytes = result.reclaimed
        storageUsage = result.after
    }

    /// Re-runs cleanup on demand, for the storage menu.
    func freeUpSpace() async {
        await reclaimStorage()
    }

    func refreshStorageUsage() async {
        storageUsage = await Task.detached(priority: .utility) {
            ModelStorageReport.current().total
        }.value
    }

    private func recordProgress(_ progress: Float) {
        downloadProgress = progress
        loadPhase = progress >= 1.0 ? .preparing : .downloading

        // ETA from the observed rate. The SDK reports a fraction only — there are no
        // byte totals to show — so elapsed and projected time are the honest ceiling.
        guard let loadStart, progress > 0.01, progress < 1.0 else {
            estimatedSecondsRemaining = nil
            return
        }
        let elapsed = Date().timeIntervalSince(loadStart)
        let projectedTotal = elapsed / Double(progress)
        estimatedSecondsRemaining = max(1, Int((projectedTotal - elapsed).rounded()))
    }

    private func startLoadClock() {
        loadStart = Date()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let start = self.loadStart else { return }
                self.elapsedSeconds = Int(Date().timeIntervalSince(start))
            }
        }
    }

    private func stopLoadClock() {
        timerTask?.cancel()
        timerTask = nil
    }

    // MARK: - Image selection

    /// Replaces the image and clears the transcript, which belonged to the old one.
    /// The new `imageID` is what tells the engine to drop the previous image's context.
    func select(_ newImage: UIImage) {
        cancelGeneration()
        image = newImage
        imageID = UUID()
        turns = []
        question = Constants.Prompt.defaultQuestion
    }

    // MARK: - Asking

    func ask(_ prompt: String? = nil) {
        if let prompt { question = prompt }
        guard canAsk, let image else { return }

        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let askedImageID = imageID

        turns.append(VisionTurn(question: text))
        question = Constants.Prompt.defaultQuestion
        isGenerating = true

        generationTask = Task { [weak self] in
            guard let self else { return }
            let started = Date()
            var sawFirstToken = false

            do {
                // Conversion is CPU-bound on a full-resolution photo; keep it off main.
                let rgb = try await Task.detached(priority: .userInitiated) {
                    try image.zeticRGBImage()
                }.value

                let stream = try await self.engine.answer(
                    question: text,
                    image: rgb,
                    imageID: askedImageID
                )

                for try await piece in stream {
                    if Task.isCancelled { break }
                    if !sawFirstToken {
                        sawFirstToken = true
                        self.markFirstToken(msSinceStart: Self.elapsedMs(since: started))
                    }
                    self.appendToLastTurn(piece)
                }
                self.finishLastTurn(durationMs: Self.elapsedMs(since: started))
                TraceLog.write("answer for imageID=\(askedImageID.uuidString.prefix(8)): \(self.turns.last?.answer.prefix(200) ?? "")")
            } catch is CancellationError {
                self.finishLastTurn(durationMs: Self.elapsedMs(since: started))
            } catch {
                self.failLastTurn(error.localizedDescription)
            }
            self.isGenerating = false
            self.generationTask = nil
        }
    }

    /// Re-runs the most recent question.
    func regenerateLast() {
        guard !isGenerating, let last = turns.last else { return }
        turns.removeLast()
        ask(last.question)
    }

    func cancelGeneration() {
        generationTask?.cancel()
        generationTask = nil
        isGenerating = false
        if let index = turns.indices.last, turns[index].isStreaming {
            turns[index].phase = .finished
        }
    }

    func cleanUp() {
        cancelGeneration()
        stopLoadClock()
        Task { [engine] in await engine.close() }
    }

    // MARK: - Transcript updates

    private static func elapsedMs(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }

    private func markFirstToken(msSinceStart: Int) {
        guard let index = turns.indices.last else { return }
        turns[index].firstTokenMs = msSinceStart
        turns[index].phase = .answering
    }

    private func appendToLastTurn(_ piece: String) {
        guard let index = turns.indices.last else { return }
        turns[index].answer += piece
    }

    private func finishLastTurn(durationMs: Int) {
        guard let index = turns.indices.last, turns[index].isStreaming else { return }
        turns[index].durationMs = durationMs
        turns[index].phase = .finished
    }

    private func failLastTurn(_ message: String) {
        guard let index = turns.indices.last else { return }
        turns[index].failure = message
        turns[index].phase = .failed
    }
}
