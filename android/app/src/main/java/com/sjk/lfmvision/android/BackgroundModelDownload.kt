package com.sjk.lfmvision.android

import android.content.Context
import com.zeticai.mlange.core.background.BackgroundDownloadHandle
import com.zeticai.mlange.core.background.BackgroundDownloadState
import com.zeticai.mlange.core.background.BackgroundDownloadStatus
import com.zeticai.mlange.core.background.ModelRemovalResult
import com.zeticai.mlange.core.cache.ModelCacheHandlingPolicy
import com.zeticai.mlange.core.model.llm.LLMModelMode
import com.zeticai.mlange.core.model.llm.ZeticMLangeLLMModel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

data class BackgroundModelDownloadState(
    val state: BackgroundDownloadState,
    val errorMessage: String? = null,
    val isStatusLookupFailure: Boolean = false,
) {
    val isActive: Boolean
        get() = state in ACTIVE_STATES

    val isInstalled: Boolean
        get() = state == BackgroundDownloadState.INSTALLED

    private companion object {
        val ACTIVE_STATES = setOf(
            BackgroundDownloadState.QUEUED,
            BackgroundDownloadState.RESOLVING,
            BackgroundDownloadState.DOWNLOADING,
            BackgroundDownloadState.VERIFYING,
        )
    }
}

/** Persists the consent decision and SDK handle; the SDK itself owns background transfer work. */
class LfmBackgroundModelDownload(
    context: Context,
    private val personalKey: String,
) {
    private val applicationContext = context.applicationContext
    private val preferences = applicationContext.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)
    private val operationMutex = Mutex()

    val hasConsent: Boolean
        get() = preferences.getBoolean(CONSENT_KEY, false)

    suspend fun scheduleIfConsented(): BackgroundModelDownloadState? = withContext(Dispatchers.IO) {
        if (!hasConsent || personalKey.isBlank()) return@withContext null
        val existing = refresh()
        if (existing != null && (existing.isStatusLookupFailure || existing.isActive || existing.isInstalled)) {
            return@withContext existing
        }
        schedule()
    }

    suspend fun grantConsentAndSchedule(): BackgroundModelDownloadState = withContext(Dispatchers.IO) {
        operationMutex.withLock {
            currentCoroutineContext().ensureActive()
            preferences.edit().putBoolean(CONSENT_KEY, true).apply()
            scheduleLocked()
        }
    }

    suspend fun refresh(): BackgroundModelDownloadState? = withContext(Dispatchers.IO) {
        val id = preferences.getString(HANDLE_KEY, null) ?: return@withContext null
        try {
            val status = ZeticMLangeLLMModel.getBackgroundDownloadStatus(applicationContext, BackgroundDownloadHandle(id))
            currentCoroutineContext().ensureActive()
            status.toUiState()
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            BackgroundModelDownloadState(BackgroundDownloadState.FAILED, error.message, isStatusLookupFailure = true)
        }
    }

    suspend fun removeDownloadedModel(): ModelRemovalResult = withContext(Dispatchers.IO) {
        operationMutex.withLock {
            currentCoroutineContext().ensureActive()
            val result = ZeticMLangeLLMModel.removeDownloadedModel(
                context = applicationContext,
                name = VisionEngine.MODEL_NAME,
            )
            currentCoroutineContext().ensureActive()
            if (!result.isInUse) clearConsentAndHandleLocked()
            result
        }
    }

    private fun clearConsentAndHandleLocked() {
        preferences.edit().remove(CONSENT_KEY).remove(HANDLE_KEY).apply()
    }

    private suspend fun schedule(): BackgroundModelDownloadState = operationMutex.withLock { scheduleLocked() }

    private suspend fun scheduleLocked(): BackgroundModelDownloadState = try {
        currentCoroutineContext().ensureActive()
        if (!hasConsent || personalKey.isBlank()) throw CancellationException()
        val handle = ZeticMLangeLLMModel.downloadInBackground(
            context = applicationContext,
            personalKey = personalKey,
            name = VisionEngine.MODEL_NAME,
            version = null,
            modelMode = LLMModelMode.RUN_AUTO,
            cacheHandlingPolicy = ModelCacheHandlingPolicy.KEEP_EXISTING,
        )
        currentCoroutineContext().ensureActive()
        preferences.edit().putString(HANDLE_KEY, handle.id).apply()
        val status = ZeticMLangeLLMModel.getBackgroundDownloadStatus(applicationContext, handle)
        currentCoroutineContext().ensureActive()
        status.toUiState()
    } catch (error: CancellationException) {
        throw error
    } catch (error: Throwable) {
        BackgroundModelDownloadState(BackgroundDownloadState.FAILED, error.message, isStatusLookupFailure = true)
    }

    private companion object {
        const val PREFERENCES_NAME = "lfm-vision-model-download"
        const val CONSENT_KEY = "model.downloadConsent"
        const val HANDLE_KEY = "model.backgroundDownloadHandle"
    }
}

private fun BackgroundDownloadStatus.toUiState() = BackgroundModelDownloadState(
    state = state,
    errorMessage = errorMessage,
)
