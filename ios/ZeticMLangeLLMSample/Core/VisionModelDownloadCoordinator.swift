import Foundation
import ZeticMLange

/// Keeps the SDK's background-download handle across launches and exposes only the states the
/// vision UI needs. The foreground model is initialized separately after this coordinator reports
/// that its SDK-managed artifacts are installed.
@MainActor
final class VisionModelDownloadCoordinator: ObservableObject {
    enum Phase: Equatable {
        case idle
        case queued
        case resolving
        case downloading(Double?)
        case verifying
        case installed
        case failed(String)
        case stopped

        var isInProgress: Bool {
            switch self {
            case .queued, .resolving, .downloading, .verifying: true
            case .idle, .installed, .failed, .stopped: false
            }
        }

        var title: String {
            switch self {
            case .queued, .resolving, .downloading, .verifying:
                "Download in progress"
            case .installed:
                "Model downloaded"
            case .failed:
                "Model download failed"
            case .stopped:
                "Model download stopped"
            case .idle:
                "Model not downloaded"
            }
        }

        var detail: String? {
            switch self {
            case .queued:
                return "Waiting to begin."
            case .resolving:
                return "Preparing the download."
            case let .downloading(progress):
                guard let progress else { return "Downloading the model." }
                return "Downloading model \(Int((progress * 100).rounded()))%"
            case .verifying:
                return "Verifying the downloaded model."
            case let .failed(message):
                return message
            case .idle, .installed, .stopped:
                return nil
            }
        }
    }

    enum RemovalOutcome: Equatable {
        case removed
        case inUse
        case failed(String)
    }

    private static let consentKey = "visionModel.backgroundDownloadConsent"
    private static let handleKey = "visionModel.backgroundDownloadHandle"

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var isRemoving = false

    private let defaults: UserDefaults
    private var scheduleTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    deinit {
        scheduleTask?.cancel()
        pollTask?.cancel()
    }

    var hasDownloadConsent: Bool { defaults.bool(forKey: Self.consentKey) }
    var isBackgroundDownloadInProgress: Bool { phase.isInProgress }
    var canUseDownloadedModel: Bool { phase == .installed }

    var failureMessage: String? {
        switch phase {
        case let .failed(message):
            message
        case .stopped:
            "The model download was stopped."
        case .idle, .queued, .resolving, .downloading, .verifying, .installed:
            nil
        }
    }

    /// A returning user already agreed to this transfer, so resume the persisted SDK task without
    /// prompting again.
    func resumeIfConsented() {
        guard hasDownloadConsent else { return }
        scheduleIfNeeded()
    }

    func recordConsent() {
        defaults.set(true, forKey: Self.consentKey)
        scheduleIfNeeded()
    }

    func retry() {
        guard hasDownloadConsent else { return }
        scheduleIfNeeded()
    }

    func removeDownloadedModel() async -> RemovalOutcome {
        guard !isRemoving else { return .failed("The model removal is already in progress.") }
        isRemoving = true
        defer { isRemoving = false }

        let activePollTask = pollTask
        let activeScheduleTask = scheduleTask
        activePollTask?.cancel()
        activeScheduleTask?.cancel()
        pollTask = nil
        scheduleTask = nil
        await activeScheduleTask?.value
        await activePollTask?.value

        if let handle = storedHandle {
            // A completed task may disappear between polling and this request. The authoritative
            // removal result below determines whether model artifacts remain.
            _ = try? await ZeticMLangeLLMModel.stopBackgroundDownload(handle)
        }

        do {
            let result = try await ZeticMLangeLLMModel.removeDownloadedModel(
                name: Constants.MLANGE.modelName
            )
            guard !result.isInUse else { return .inUse }
            clearConsentAndHandle()
            phase = .idle
            return .removed
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private var storedHandle: BackgroundDownloadHandle? {
        get { defaults.string(forKey: Self.handleKey).map(BackgroundDownloadHandle.init(id:)) }
        set {
            if let newValue {
                defaults.set(newValue.id, forKey: Self.handleKey)
            } else {
                defaults.removeObject(forKey: Self.handleKey)
            }
        }
    }

    private func clearConsentAndHandle() {
        defaults.removeObject(forKey: Self.consentKey)
        storedHandle = nil
    }

    private func scheduleIfNeeded() {
        guard !isRemoving, !phase.isInProgress, phase != .installed else { return }
        phase = .queued
        scheduleTask?.cancel()
        scheduleTask = Task { [weak self] in
            await self?.scheduleOrResume()
        }
    }

    private func scheduleOrResume() async {
        defer { scheduleTask = nil }
        guard hasDownloadConsent, !isRemoving else { return }

        if let handle = storedHandle {
            await refresh(handle)
            if phase.isInProgress { startPolling(handle) }
            return
        }

        guard let personalKey = Constants.MLANGE.personalAccessKey?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !personalKey.isEmpty,
            personalKey != "dev_YOUR_KEY_HERE"
        else {
            phase = .failed("Set a personal key before downloading the model.")
            return
        }

        do {
            let handle = try await ZeticMLangeLLMModel.downloadInBackground(
                personalKey: personalKey,
                name: Constants.MLANGE.modelName,
                cacheHandlingPolicy: .KEEP_EXISTING
            )
            guard !isRemoving, !Task.isCancelled else {
                _ = try? await ZeticMLangeLLMModel.stopBackgroundDownload(handle)
                return
            }
            storedHandle = handle
            await refresh(handle)
            if phase.isInProgress { startPolling(handle) }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func startPolling(_ handle: BackgroundDownloadHandle) {
        guard !isRemoving else { return }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard !self.isRemoving else { return }
                await self.refresh(handle)
                guard !self.isRemoving, self.phase.isInProgress else { return }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func refresh(_ handle: BackgroundDownloadHandle) async {
        do {
            let status = try await ZeticMLangeLLMModel.getBackgroundDownloadStatus(handle)
            guard !isRemoving, !Task.isCancelled else { return }
            switch status.state {
            case .queued:
                phase = .queued
            case .resolving:
                phase = .resolving
            case .downloading:
                let progress: Double? = status.totalBytes.flatMap { total in
                    guard total > 0 else { return nil }
                    return min(1, max(0, Double(status.bytesDownloaded) / Double(total)))
                }
                phase = .downloading(progress)
            case .verifying:
                phase = .verifying
            case .installed:
                phase = .installed
            case .failed:
                phase = .failed(status.errorMessage ?? "The model could not be downloaded.")
                storedHandle = nil
            case .stopped:
                phase = .stopped
                storedHandle = nil
            @unknown default:
                phase = .failed("The model returned an unsupported download status.")
                storedHandle = nil
            }
        } catch {
            guard !isRemoving, !Task.isCancelled else { return }
            phase = .failed(error.localizedDescription)
        }
    }
}
