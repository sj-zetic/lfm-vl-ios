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
        guard let model else { throw VisionEngineError.notLoaded }

        // NSLog rather than Logger: devicectl --console streams stdout/stderr only.
        // The fingerprint proves whether a genuinely different image reaches the
        // model, which separates "context not cleared" from "wrong image passed".
        TraceLog.write("ask imageID=\(imageID.uuidString.prefix(8)) contextImageID=\(contextImageID?.uuidString.prefix(8) ?? "none") rgb=\(image.width)x\(image.height) fingerprint=\(Self.fingerprint(of: image))")

        switch contextImageID {
        case nil:
            // First question of the session: nothing in context to clear.
            TraceLog.write("first image -> nothing to clear")
        case imageID:
            TraceLog.write("same image -> keeping context")
        default:
            try clearContext(on: model)
        }
        contextImageID = imageID

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
    /// `respond` appends to a live transcript, so skipping this leaves the previous
    /// photo's answer in context *and* puts the new image on the first user turn,
    /// which is why the second photo used to be answered with the first photo's
    /// description. `cleanUp` is the reset this backend supports: it clears the
    /// transcript, the KV cache, and the staged image in one call.
    ///
    /// The earlier attempt used `resetKVState()`, which is implemented only for
    /// KV-persistence-capable backends (llama.cpp) and always throws here — that
    /// throw is what made this look unfixable.
    private func clearContext(on model: ZeticMLangeLLMModel) throws {
        do {
            try model.cleanUp()
            TraceLog.write("image changed -> context cleared")
        } catch {
            // Not expected. Surface it rather than answer about the previous photo.
            TraceLog.write("cleanUp THREW: \(error.localizedDescription)")
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
        guard let personalAccessKey = Constants.MLANGE.personalAccessKey?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !personalAccessKey.isEmpty,
            personalAccessKey != "dev_YOUR_KEY_HERE"
        else {
            throw VisionEngineError.missingPersonalAccessKey
        }

        TraceLog.startSession()
        // The candidate this device is served (prefill=GPU / decode=NPU) is memory
        // hungry, and a VL turn only needs 64-256 image tokens plus a short
        // question, so the default 2048 context buys nothing here.
        let model = try await ZeticMLangeLLMModel(
            personalKey: personalAccessKey,
            name: Constants.MLANGE.modelName,
            modelMode: .RUN_AUTO,
            initOption: LLMInitOption(nCtx: 1024),
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
    case missingPersonalAccessKey
    case contextResetFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .notLoaded:
            return "The model is not loaded yet."
        case .missingPersonalAccessKey:
            return "Set a valid MLANGE_PERSONAL_KEY in the app scheme before loading the model."
        case .contextResetFailed(let underlying):
            return "Could not clear the previous image from the model: \(underlying.localizedDescription)"
        }
    }
}
