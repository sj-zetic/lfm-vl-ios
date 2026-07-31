import Foundation

/// One question-and-answer exchange about the currently selected image.
struct VisionTurn: Identifiable {
    enum Phase {
        /// The image is being encoded and prefilled — the slow part on a VLM.
        case readingImage
        /// Tokens are arriving.
        case answering
        case finished
        case failed
    }

    let id = UUID()
    let question: String
    var answer: String = ""
    var failure: String?
    var phase: Phase = .readingImage

    /// Time to first token, and total stream duration — both worth surfacing when
    /// inference runs on the phone rather than a server.
    var firstTokenMs: Int?
    var durationMs: Int?

    var isStreaming: Bool {
        phase == .readingImage || phase == .answering
    }

    /// Tokens/sec, approximated from characters since the SDK streams text pieces
    /// rather than token counts.
    var approximateTokensPerSecond: Double? {
        guard
            let durationMs, durationMs > 0,
            let firstTokenMs,
            durationMs > firstTokenMs,
            !answer.isEmpty
        else { return nil }
        let generationSeconds = Double(durationMs - firstTokenMs) / 1000
        guard generationSeconds > 0 else { return nil }
        return (Double(answer.count) / 4.0) / generationSeconds
    }
}
