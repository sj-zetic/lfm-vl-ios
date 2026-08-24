import Foundation

struct Constants {
    struct MLANGE {
        static let personalAccessKey =
            Bundle.main.object(forInfoDictionaryKey: "PERSONAL_KEY") as? String
        static let modelName = "changgeun/LFM2.5-VL-450M"
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
