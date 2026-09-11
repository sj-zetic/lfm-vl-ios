package com.sjk.lfmvision.android

import android.app.Application
import android.graphics.Bitmap
import android.net.Uri
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.zeticai.mlange.core.background.BackgroundDownloadState
import com.zeticai.mlange.core.model.llm.ZeticMLangeLLMModel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

enum class ModelStatus { AWAITING_CONSENT, DOWNLOADING, INITIALIZING, READY, GENERATING, REMOVING, FAILURE }

data class VisionUiState(
    val status: ModelStatus = ModelStatus.AWAITING_CONSENT,
    val message: String = "Download the on-device model to continue.",
    val prompt: String = VisionViewModel.DEFAULT_PROMPT,
    val imageUri: Uri? = null,
    val preview: Bitmap? = null,
    val turns: List<VisionTurn> = emptyList(),
    val imageUpdating: Boolean = false,
    val backgroundDownload: BackgroundModelDownloadState? = null,
) {
    val canAsk get() = status == ModelStatus.READY && preview != null && prompt.isNotBlank() && !imageUpdating
    val hasTranscript get() = turns.isNotEmpty()
    val canRemoveDownloadedModel get() = backgroundDownload != null && status !in setOf(ModelStatus.GENERATING, ModelStatus.INITIALIZING, ModelStatus.REMOVING)
}

class VisionViewModel(application: Application) : AndroidViewModel(application) {
    private val engine = VisionEngine(application.applicationContext)
    private val _uiState = MutableStateFlow(VisionUiState())
    val uiState = _uiState.asStateFlow()
    private var image: ZeticMLangeLLMModel.Image? = null
    private var imageUpdateInProgress = false
    private val engineWork = EngineWorkQueue()
    private val modelDownload = LfmBackgroundModelDownload(application.applicationContext, BuildConfig.ZETIC_PERSONAL_KEY)
    private var backgroundDownloadJob: Job? = null
    private val backgroundDownloadGeneration = AtomicLong()
    private val backgroundDownloadStateLock = Any()
    private val modelRemovalInProgress = AtomicBoolean()
    private var turnId = 0L
    private var generationId = 0L
    private var activeGenerationId: Long? = null

    init { if (isUsablePersonalKey(BuildConfig.ZETIC_PERSONAL_KEY)) prepareBackgroundDownload() else showMissingKey() }

    fun updatePrompt(prompt: String) = _uiState.update { it.copy(prompt = prompt) }

    fun retryInitialize() {
        if (isUsablePersonalKey(BuildConfig.ZETIC_PERSONAL_KEY)) {
            prepareBackgroundDownload()
        } else showMissingKey()
    }

    /** This is called only from the consent surface, so a new transfer is never implicit. */
    fun approveModelDownload() {
        if (modelRemovalInProgress.get()) return
        if (!isUsablePersonalKey(BuildConfig.ZETIC_PERSONAL_KEY)) {
            showMissingKey()
            return
        }
        val generation = invalidateBackgroundDownloadWork()
        runForCurrentBackgroundDownload(generation) {
            _uiState.update {
                it.copy(
                    status = ModelStatus.DOWNLOADING,
                    message = "Model download in progress",
                    backgroundDownload = BackgroundModelDownloadState(BackgroundDownloadState.QUEUED),
                )
            }
        }
        backgroundDownloadJob = viewModelScope.launch {
            val download = modelDownload.grantConsentAndSchedule()
            if (!isCurrentBackgroundDownload(generation)) return@launch
            observeBackgroundDownload(download, generation)
        }
    }

    /** A returning user can resume only the download they have already approved. */
    private fun prepareBackgroundDownload() {
        if (modelRemovalInProgress.get()) return
        if (!modelDownload.hasConsent) {
            val generation = invalidateBackgroundDownloadWork()
            runForCurrentBackgroundDownload(generation) {
                _uiState.update {
                    it.copy(
                        status = ModelStatus.AWAITING_CONSENT,
                        message = "Download the on-device model to continue.",
                        backgroundDownload = null,
                    )
                }
            }
            return
        }
        val generation = invalidateBackgroundDownloadWork()
        backgroundDownloadJob = viewModelScope.launch {
            val download = modelDownload.scheduleIfConsented()
            if (!isCurrentBackgroundDownload(generation)) return@launch
            if (download == null) showMissingKey() else observeBackgroundDownload(download, generation)
        }
    }

    private suspend fun observeBackgroundDownload(initial: BackgroundModelDownloadState, generation: Long) {
        if (!isCurrentBackgroundDownload(generation)) return
        var download = initial
        publishDownloadStatus(download, generation)
        while (download.isActive) {
            delay(BACKGROUND_DOWNLOAD_POLL_INTERVAL_MILLIS)
            val refreshed = modelDownload.refresh() ?: break
            if (!isCurrentBackgroundDownload(generation)) return
            download = refreshed
            publishDownloadStatus(download, generation)
        }
        if (download.isInstalled && isCurrentBackgroundDownload(generation)) initialize(generation)
    }

    private fun publishDownloadStatus(download: BackgroundModelDownloadState, generation: Long) {
        runForCurrentBackgroundDownload(generation) {
            _uiState.update {
                when {
                    download.isActive -> it.copy(
                        status = ModelStatus.DOWNLOADING,
                        message = "Model download in progress",
                        backgroundDownload = download,
                    )
                    download.isInstalled -> it.copy(
                        status = ModelStatus.INITIALIZING,
                        message = "Initializing model…",
                        backgroundDownload = download,
                    )
                    else -> it.copy(
                        status = ModelStatus.FAILURE,
                        message = download.errorMessage ?: "Model download could not be completed.",
                        backgroundDownload = download,
                    )
                }
            }
        }
    }

    /** Removes only SDK-managed model files after the idle runtime releases its handle. */
    fun removeDownloadedModel() {
        val current = _uiState.value
        if (!current.canRemoveDownloadedModel || !modelRemovalInProgress.compareAndSet(false, true)) {
            _uiState.update { it.copy(message = "Finish the active response before removing the model.") }
            return
        }
        val generation = invalidateBackgroundDownloadWork()
        runForCurrentBackgroundDownload(generation) {
            _uiState.update { it.copy(status = ModelStatus.REMOVING, message = "Removing downloaded model…") }
        }
        engineWork.launch {
            runCatching {
                engine.close()
                modelDownload.removeDownloadedModel()
            }.onSuccess { removal ->
                runForCurrentBackgroundDownload(generation) {
                    modelRemovalInProgress.set(false)
                    if (removal.isInUse) {
                        _uiState.update {
                            it.copy(status = ModelStatus.FAILURE, message = "Finish the active response before removing the model.")
                        }
                    } else {
                        _uiState.update {
                            it.copy(
                                status = ModelStatus.AWAITING_CONSENT,
                                message = "Downloaded model removed. Downloading it again requires your consent.",
                                backgroundDownload = null,
                            )
                        }
                    }
                }
            }.onFailure { error ->
                if (error !is CancellationException) runForCurrentBackgroundDownload(generation) {
                    modelRemovalInProgress.set(false)
                    _uiState.update { it.copy(status = ModelStatus.FAILURE, message = error.message ?: "Could not remove the downloaded model.") }
                }
            }
        }
    }

    private fun invalidateBackgroundDownloadWork(): Long = synchronized(backgroundDownloadStateLock) {
        val generation = backgroundDownloadGeneration.incrementAndGet()
        backgroundDownloadJob?.cancel()
        backgroundDownloadJob = null
        generation
    }

    private fun isCurrentBackgroundDownload(generation: Long) =
        backgroundDownloadGeneration.get() == generation

    /** Pairs a generation check with its UI write so a cancelled worker cannot publish afterward. */
    private fun runForCurrentBackgroundDownload(generation: Long, update: () -> Unit) {
        synchronized(backgroundDownloadStateLock) {
            if (backgroundDownloadGeneration.get() == generation) update()
        }
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

    private fun initialize(generation: Long) {
        if (!isCurrentBackgroundDownload(generation)) return
        engineWork.launch {
            if (!isCurrentBackgroundDownload(generation)) return@launch
            runCatching {
                engine.initialize(BuildConfig.ZETIC_PERSONAL_KEY, modelProgress@{ progress ->
                    runForCurrentBackgroundDownload(generation) {
                        _uiState.update { it.copy(status = ModelStatus.INITIALIZING, message = "Initializing — preparing model ${(progress * 100).toInt()}%") }
                    }
                })
            }.onSuccess {
                runForCurrentBackgroundDownload(generation) {
                    _uiState.update { it.copy(status = ModelStatus.READY, message = "Ready") }
                }
            }.onFailure { error ->
                if (error !is CancellationException) runForCurrentBackgroundDownload(generation) { fail(error) }
            }
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

    override fun onCleared() {
        invalidateBackgroundDownloadWork()
        engineWork.close { engine.close() }
        super.onCleared()
    }

    companion object {
        const val DEFAULT_PROMPT = "What is this image about?"
        val suggestions = listOf("Describe this", "Read the text", "What object is this?", "What's happening?")
        fun isUsablePersonalKey(key: String) = key.isNotBlank() && !key.contains("YOUR_KEY", true) && !key.startsWith("dev_YOUR")
        private const val BACKGROUND_DOWNLOAD_POLL_INTERVAL_MILLIS = 1_000L
    }
}
