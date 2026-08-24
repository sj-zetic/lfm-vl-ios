package com.sjk.lfmvision.android

enum class TurnPhase { READING, ANSWERING, FINISHED, FAILED }

data class VisionTurn(
    val id: Long,
    val question: String,
    val answer: String = "",
    val phase: TurnPhase = TurnPhase.READING,
    val failure: String? = null,
    val firstTokenMillis: Long? = null,
    val durationMillis: Long? = null,
) {
    val isStreaming: Boolean get() = phase == TurnPhase.READING || phase == TurnPhase.ANSWERING

    val performance: String?
        get() {
            val first = firstTokenMillis ?: return null
            val duration = durationMillis ?: return "${first / 1000.0}s to first token"
            val generationMillis = duration - first
            val tokensPerSecond = if (generationMillis > 0 && answer.isNotEmpty()) (answer.length / 4.0) / (generationMillis / 1000.0) else null
            return buildString {
                append("${first / 1000.0}s to first token")
                tokensPerSecond?.let { append(" · ~${it.toInt()} tok/s") }
            }
        }
}
