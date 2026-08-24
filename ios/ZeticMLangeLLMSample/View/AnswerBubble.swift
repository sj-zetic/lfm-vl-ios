import SwiftUI

struct AnswerBubble: View {
    let turn: VisionTurn
    let isLast: Bool
    let onRegenerate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(turn.question)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(10)
                .background(Color.accentColor.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 14))

            if let failure = turn.failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if turn.answer.isEmpty && turn.isStreaming {
                statusLabel
            } else {
                answerBody
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    /// Image prefill is the slow phase on a VLM, so it gets its own wording rather
    /// than a generic spinner that makes the app look hung.
    private var statusLabel: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(statusText)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var statusText: String {
        switch turn.phase {
        case .readingImage: return "Reading image…"
        default: return "Answering…"
        }
    }

    private var answerBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(turn.answer)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 14))

            if !turn.isStreaming {
                HStack(spacing: 14) {
                    if let metrics = metricsText {
                        Text(metrics)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    Spacer()

                    Button {
                        UIPasteboard.general.string = turn.answer
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .accessibilityLabel("Copy answer")

                    ShareLink(item: turn.answer) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share answer")

                    if isLast {
                        Button(action: onRegenerate) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .accessibilityLabel("Ask again")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            }
        }
    }

    /// Time-to-first-token and throughput matter when inference runs on the phone.
    private var metricsText: String? {
        guard let firstTokenMs = turn.firstTokenMs else { return nil }
        var parts = ["\(String(format: "%.1f", Double(firstTokenMs) / 1000))s to first token"]
        if let tps = turn.approximateTokensPerSecond {
            parts.append("~\(String(format: "%.0f", tps)) tok/s")
        }
        return parts.joined(separator: " · ")
    }
}
