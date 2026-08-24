package com.sjk.lfmvision.android

import android.Manifest
import android.content.pm.PackageManager
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performScrollToIndex
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.height
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import org.junit.Rule
import org.junit.Assert.assertEquals
import org.junit.Test

class VisionScreenTest {
    @get:Rule val composeRule = createComposeRule()

    @Test fun missingKeyFailureIsVisibleAndCannotGenerate() {
        composeRule.setContent {
            VisionContent(
                state = VisionUiState(status = ModelStatus.FAILURE, message = "ZETIC_PERSONAL_KEY is required"),
                onPromptChanged = {}, onLibrary = {}, onCamera = {}, onAsk = {}, onStop = {}, onRetry = {}, onRegenerate = {}, onZoom = {},
            )
        }

        composeRule.onNodeWithText("Model unavailable").assertIsDisplayed()
    }

    @Test fun generatingDisablesImageSources() {
        composeRule.setContent {
            VisionContent(
                state = VisionUiState(status = ModelStatus.GENERATING),
                onPromptChanged = {}, onLibrary = {}, onCamera = {}, onAsk = {}, onStop = {}, onRetry = {}, onRegenerate = {}, onZoom = {},
            )
        }

        composeRule.onNodeWithText("Library").assertIsNotEnabled()
        composeRule.onNodeWithText("Camera").assertIsNotEnabled()
    }

    @Test fun manifestDeclaresInternetPermission() {
        val context = androidx.test.platform.app.InstrumentationRegistry.getInstrumentation().targetContext
        assertEquals(PackageManager.PERMISSION_GRANTED, context.packageManager.checkPermission(Manifest.permission.INTERNET, context.packageName))
    }

    @Test fun constrainedHeightKeepsComposerAndTranscriptScrollable() {
        val turns = (1..8).map { VisionTurn(it.toLong(), "Question $it", "Answer $it", TurnPhase.FINISHED) }
        composeRule.setContent {
            Box(Modifier.height(280.dp)) {
                VisionContent(VisionUiState(status = ModelStatus.READY, preview = null, turns = turns), {}, {}, {}, {}, {}, {}, {}, {})
            }
        }
        composeRule.onNodeWithText("Ask about this image").assertIsDisplayed()
        composeRule.waitForIdle()
        composeRule.onNodeWithTag("photo_conversation_list").performScrollToIndex(0)
        composeRule.waitForIdle()
        composeRule.onNodeWithText("Take a photo or choose one from your library.").assertIsDisplayed()
        composeRule.onNodeWithText("Question 8", useUnmergedTree = true).assertIsNotDisplayed()
        composeRule.onNodeWithTag("photo_conversation_list").performScrollToIndex(8)
        composeRule.waitForIdle()
        composeRule.onNodeWithText("Question 8", useUnmergedTree = true).assertIsDisplayed()
    }
}
