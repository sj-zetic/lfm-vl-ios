import Foundation
import OSLog
import ZeticMLange

/// Owns the on-device model.
///
/// This is an actor so the model is created and prefilled off the main thread —
/// both `ZeticMLangeLLMModel.init` and `respond` block for a noticeable time on a
/// 450M vision model, and neither may run on the UI thread.
actor VisionEngine {
    private static let log = Logger(subsystem: "com.sjk.lfmvision", category: "VisionEngine")

    private var model: ZeticMLangeLLMModel?

    /// Identity of the image whose tokens are currently in the model's context.
    private var contextImageID: UUID?

    /// Each rebuild costs a full CoreML recompile and leaves another ~700 MB of
    /// artifacts on disk, so it is allowed at most once per session.
    private var hasRebuilt = false

    var isLoaded: Bool { model != nil }

    /// Downloads (first launch only) and loads the model. Subsequent calls are no-ops.
    func load(onProgress: @escaping @Sendable (Float) -> Void) async throws {
        guard model == nil else { return }
        model = try await makeModel(onProgress: onProgress)
    }

    /// Streams an answer about `image`.
    ///
    /// Context is deliberately *kept* between questions about the same image, so
    /// follow-ups work, and cleared when the image changes, so an answer never
    /// describes the previous photo.
    func answer(
        question: String,
        image: ZeticMLangeLLMModel.Image,
        imageID: UUID
    ) async throws -> AsyncThrowingStream<String, Error> {
        guard model != nil else { throw VisionEngineError.notLoaded }

        // NSLog rather than Logger: devicectl --console streams stdout/stderr only.
        // The fingerprint proves whether a genuinely different image reaches the
        // model, which separates "context not cleared" from "wrong image passed".
        TraceLog.write("ask imageID=\(imageID.uuidString.prefix(8)) contextImageID=\(contextImageID?.uuidString.prefix(8) ?? "none") rgb=\(image.width)x\(image.height) fingerprint=\(Self.fingerprint(of: image))")

        switch contextImageID {
        case nil:
            // First question of the session: nothing in context to clear. Clearing
            // here crashed before any answer could be produced.
            TraceLog.write("first image -> nothing to clear")
            contextImageID = imageID
        case imageID:
            TraceLog.write("same image -> keeping context")
        default:
            // DIAGNOSTIC: the MLLM backend reports no KV persistence, which implies
            // respond() is already stateless. Proceed without clearing so an A→B
            // trace shows whether the answer actually follows the new fingerprint.
            TraceLog.write("image changed -> proceeding WITHOUT reset (diagnostic)")
            contextImageID = imageID
        }

        guard let model else { throw VisionEngineError.notLoaded }
        return try model.respond(
            systemPrompt: Constants.Prompt.system,
            userText: question,
            image: image
        )
    }

    func close() {
        model?.close()
        model = nil
        contextImageID = nil
    }

    // MARK: - Context

    /// Drops the previous image's tokens from the model's context.
    ///
    /// The failure was `try? model.resetKVState()`: a throw here means the old image
    /// is still in context, and swallowing it meant the next question was answered
    /// about the previous photo with no sign anything went wrong. A failed reset now
    /// falls back to rebuilding the model, which reloads from the on-device cache
    /// rather than the network.
    private func clearContext() async throws {
        guard let model else { throw VisionEngineError.notLoaded }

        do {
            try model.resetKVState()
            TraceLog.write("resetKVState succeeded")
        } catch {
            // On the MLLM (CoreML) backend this always throws — reset is only
            // implemented for KV-persistence-capable backends, i.e. LLAMA_CPP.
            // Rebuilding the model here segfaulted (SIGSEGV in close/re-init), so
            // fail loudly rather than crash or answer about the previous photo.
            TraceLog.write("resetKVState THREW: \(error.localizedDescription)")
            throw VisionEngineError.contextResetUnsupported(underlying: error)
        }
    }

    /// Recreates the model from the on-device cache, discarding all context with it.
    private func rebuild() async throws {
        guard !hasRebuilt else {
            Self.log.warning("skipping second rebuild this session; context may be stale")
            return
        }
        hasRebuilt = true
        model?.close()
        model = nil
        contextImageID = nil
        do {
            model = try await makeModel(onProgress: nil)
        } catch {
            throw VisionEngineError.contextResetFailed(underlying: error)
        }
    }

    /// Cheap FNV-1a over sampled pixels — enough to tell two photos apart in a log.
    private static func fingerprint(of image: ZeticMLangeLLMModel.Image) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        let stride = max(1, image.rgb.count / 4096)
        for index in Swift.stride(from: 0, to: image.rgb.count, by: stride) {
            hash = (hash ^ UInt64(image.rgb[index])) &* 0x100000001b3
        }
        return hash
    }

    private func makeModel(onProgress: (@Sendable (Float) -> Void)?) async throws -> ZeticMLangeLLMModel {
        TraceLog.startSession()
        TraceLog.write("requesting model quantType=\(String(describing: Constants.MLANGE.quantType))")
        let model = try await ZeticMLangeLLMModel(
            personalKey: Constants.MLANGE.personalAccessKey,
            name: Constants.MLANGE.modelName,
            modelMode: .RUN_AUTO,
            quantType: Constants.MLANGE.quantType,
            onDownload: onProgress
        )
        // The backend actually chosen shows up in the SDK's own
        // `BackendSelectionClient` log line as `ztc_id` — `gguf_*` means the
        // llama.cpp path took effect, `coreml_*` means it fell back.
        TraceLog.write("model loaded")
        return model
    }
}

enum VisionEngineError: LocalizedError {
    case notLoaded
    case contextResetFailed(underlying: Error)
    case contextResetUnsupported(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .notLoaded:
            return "The model is not loaded yet."
        case .contextResetFailed(let underlying):
            return "Could not clear the previous image from the model: \(underlying.localizedDescription)"
        case .contextResetUnsupported:
            return "This backend can't clear the previous photo from memory, so the answer would describe the old one. Restart the app to ask about a different photo."
        }
    }
}
