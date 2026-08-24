package com.sjk.lfmvision.android

import android.content.Context
import com.zeticai.mlange.core.cache.ModelCacheHandlingPolicy
import com.zeticai.mlange.core.model.llm.LLMModelMode
import com.zeticai.mlange.core.model.llm.ZeticMLangeLLMModel
import kotlinx.coroutines.flow.Flow

class VisionEngine(private val context: Context) {
    private var model: ZeticMLangeLLMModel? = null

    fun initialize(personalKey: String, onDownload: (Float) -> Unit) {
        model?.close()
        model = ZeticMLangeLLMModel(
            context = context,
            personalKey = personalKey,
            name = MODEL_NAME,
            modelMode = LLMModelMode.RUN_AUTO,
            cacheHandlingPolicy = ModelCacheHandlingPolicy.KEEP_EXISTING,
            onDownload = onDownload,
        )
    }

    fun respond(prompt: String, image: ZeticMLangeLLMModel.Image): Flow<String> =
        requireNotNull(model) { "모델이 준비되지 않았습니다." }.respond(
            systemPrompt = SYSTEM_PROMPT,
            userText = prompt,
            image = image,
        )

    fun resetSession() = model?.resetSession()

    fun close() {
        model?.close()
        model = null
    }

    companion object {
        const val MODEL_NAME = "changgeun/LFM2.5-VL-450M"
        private const val SYSTEM_PROMPT = "You are a concise vision assistant."
    }
}
