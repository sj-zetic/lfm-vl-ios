import Foundation
import ZeticMLange

struct Constants {
    // TODO: paste your personal access key.
    // Get one at https://mlange.zetic.ai/settings?tab=pat
    // Falls back to the MLANGE_PERSONAL_KEY environment variable so the key can
    // stay out of version control.
    struct MLANGE {
        static let personalAccessKey =
            ProcessInfo.processInfo.environment["MLANGE_PERSONAL_KEY"] ?? "dev_YOUR_KEY_HERE"
        static let modelName = "changgeun/LFM2.5-VL-450M"

        /// Currently inert: the selection service ignores it and serves a CoreML
        /// candidate either way. Verified on device — the request carried
        /// `GGUF_QUANT_Q4_K_M` and the response was `coreml_1f2826b9`, one of nine
        /// candidates, all CoreML.
        ///
        /// It was set in the belief that a GGUF build would avoid the CoreML path,
        /// whose `resetKVState()` throws. That premise was wrong twice over: there
        /// is no GGUF build of this model, and the way to clear context on the
        /// CoreML path is `cleanUp()`, not `resetKVState()` — see `VisionEngine`.
        static let quantType: LLMQuantType? = .GGUF_QUANT_Q4_K_M
    }

    struct Prompt {
        static let system = "You are a concise vision assistant. Answer questions about the image the user provides. Be specific and factual, and say so when the image does not show enough to answer."
        static let defaultQuestion = "What is this image about?"

        /// One-tap questions. Typing on a phone is the main cost of asking, so the
        /// common cases should never require the keyboard.
        static let suggestions = [
            "Describe this",
            "Read the text",
            "What object is this?",
            "What's happening?",
        ]
    }

    /// Longest edge, in pixels, an image is resized to before it reaches the model.
    /// The vision encoder works on a small fixed grid, so sending a full 12 MP photo
    /// costs memory and prefill time without improving the answer.
    static let maxImageDimension: CGFloat = 512
}
