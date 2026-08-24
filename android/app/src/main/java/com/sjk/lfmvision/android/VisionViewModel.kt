package com.sjk.lfmvision.android

import android.app.Application
import android.graphics.Bitmap
import android.net.Uri
import androidx.lifecycle.AndroidViewModel
import com.zeticai.mlange.core.model.llm.ZeticMLangeLLMModel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.update

enum class ModelStatus { INITIALIZING, READY, GENERATING, FAILURE }

data class VisionUiState(
    val status: ModelStatus = ModelStatus.INITIALIZING,
    val message: String = "Initializing model…",
    val prompt: String = VisionViewModel.DEFAULT_PROMPT,
    val imageUri: Uri? = null,
    val preview: Bitmap? = null,
    val turns: List<VisionTurn> = emptyList(),
    val imageUpdating: Boolean = false,
) {
    val canAsk get() = status == ModelStatus.READY && preview != null && prompt.isNotBlank() && !imageUpdating
    val hasTranscript get() = turns.isNotEmpty()
}

class VisionViewModel(application: Application) : AndroidViewModel(application) {
    private val engine = VisionEngine(application.applicationContext)
    private val _uiState = MutableStateFlow(VisionUiState())
    val uiState = _uiState.asStateFlow()
    private var image: ZeticMLangeLLMModel.Image? = null
    private var imageUpdateInProgress = false
    private val engineWork = EngineWorkQueue()
    private var turnId = 0L
    private var generationId = 0L
    private var activeGenerationId: Long? = null

    init { if (isUsablePersonalKey(BuildConfig.ZETIC_PERSONAL_KEY)) initialize() else showMissingKey() }

    fun updatePrompt(prompt: String) = _uiState.update { it.copy(prompt = prompt) }

    fun retryInitialize() {
        if (isUsablePersonalKey(BuildConfig.ZETIC_PERSONAL_KEY)) {
            _uiState.update { it.copy(status = ModelStatus.INITIALIZING, message = "Initializing model…") }
            initialize()
        } else showMissingKey()
    }

    fun selectImage(uri: Uri) {
        if (_uiState.value.status == ModelStatus.GENERATING || imageUpdateInProgress) return
        imageUpdateInProgress = true
        _uiState.update { it.copy(imageUpdating = true) }
        engineWork.launch {
            runCatching { ImageDecoder.decode(getApplication<Application>().contentResolver, uri) }
                .onSuccess { decoded ->
                    engine.resetSession()
                    image = decoded.modelImage
                    imageUpdateInProgress = false
                    _uiState.update { it.copy(imageUri = uri, preview = decoded.preview, turns = emptyList(), prompt = DEFAULT_PROMPT, imageUpdating = false, message = "Ready") }
                }
                .onFailure { error ->
                    imageUpdateInProgress = false
                    if (error !is CancellationException) fail(error)
                }
        }
    }

    fun ask(suggestion: String? = null) {
        val selectedImage = image ?: return
        val question = (suggestion ?: _uiState.value.prompt).trim()
        if (question.isBlank() || !_uiState.value.canAsk) return
        val startedAt = System.currentTimeMillis()
        val turn = VisionTurn(id = ++turnId, question = question)
        val requestId = ++generationId
        activeGenerationId = requestId
        _uiState.update { it.copy(status = ModelStatus.GENERATING, message = "Reading image…", prompt = DEFAULT_PROMPT, turns = it.turns + turn) }
        engineWork.launch {
            runCatching {
                engine.respond(question, selectedImage).collect { token ->
                    val elapsed = System.currentTimeMillis() - startedAt
                    _uiState.update { state ->
                        if (activeGenerationId != requestId) return@update state
                        state.copy(message = "Answering…", turns = state.turns.map {
                            if (it.id == turn.id) it.copy(answer = it.answer + token, phase = TurnPhase.ANSWERING, firstTokenMillis = it.firstTokenMillis ?: elapsed) else it
                        })
                    }
                }
            }.onSuccess { finishTurn(requestId, turn.id, startedAt) }
                .onFailure { error -> if (error is CancellationException) finishTurn(requestId, turn.id, startedAt) else failTurn(requestId, turn.id, error) }
        }
    }

    fun stopGeneration() {
        if (activeGenerationId == null) return
        activeGenerationId = null
        _uiState.update { state ->
            state.copy(
                status = ModelStatus.READY,
                message = "Ready",
                turns = state.turns.map { if (it.isStreaming) it.copy(phase = TurnPhase.FINISHED) else it },
            )
        }
        engineWork.cancelActive()
    }

    fun regenerateLast() {
        val last = _uiState.value.turns.lastOrNull() ?: return
        if (_uiState.value.status == ModelStatus.READY) {
            _uiState.update { it.copy(turns = it.turns.dropLast(1), prompt = last.question) }
            ask(last.question)
        }
    }

    private fun initialize() {
        engineWork.launch {
            runCatching {
                engine.initialize(BuildConfig.ZETIC_PERSONAL_KEY) { progress ->
                    _uiState.update { it.copy(status = ModelStatus.INITIALIZING, message = "Initializing — preparing model ${(progress * 100).toInt()}%") }
                }
            }.onSuccess { _uiState.update { it.copy(status = ModelStatus.READY, message = "Ready") } }
                .onFailure { error -> if (error !is CancellationException) fail(error) }
        }
    }

    private fun finishTurn(requestId: Long, id: Long, startedAt: Long) = _uiState.update { state ->
        if (activeGenerationId != requestId) return@update state
        activeGenerationId = null
        state.copy(status = ModelStatus.READY, message = "Ready", turns = state.turns.map { if (it.id == id) it.copy(phase = TurnPhase.FINISHED, durationMillis = System.currentTimeMillis() - startedAt) else it })
    }

    private fun failTurn(requestId: Long, id: Long, error: Throwable) = _uiState.update { state ->
        if (activeGenerationId != requestId) return@update state
        activeGenerationId = null
        state.copy(status = ModelStatus.READY, message = "Ready", turns = state.turns.map { if (it.id == id) it.copy(phase = TurnPhase.FAILED, failure = error.message ?: "Could not answer this question.") else it })
    }

    private fun showMissingKey() { _uiState.value = VisionUiState(status = ModelStatus.FAILURE, message = "ZETIC_PERSONAL_KEY is required before the model can initialize.") }
    private fun fail(error: Throwable) { _uiState.update { it.copy(status = ModelStatus.FAILURE, message = error.message ?: "Model unavailable", imageUpdating = false) } }

    override fun onCleared() { engineWork.close { engine.close() }; super.onCleared() }

    companion object {
        const val DEFAULT_PROMPT = "What is this image about?"
        val suggestions = listOf("Describe this", "Read the text", "What object is this?", "What's happening?")
        fun isUsablePersonalKey(key: String) = key.isNotBlank() && !key.contains("YOUR_KEY", true) && !key.startsWith("dev_YOUR")
    }
}
