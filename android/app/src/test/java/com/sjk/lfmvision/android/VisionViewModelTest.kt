package com.sjk.lfmvision.android

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VisionViewModelTest {
    @Test fun blankKeyIsRejected() = assertFalse(VisionViewModel.isUsablePersonalKey(""))
    @Test fun placeholderKeyIsRejected() = assertFalse(VisionViewModel.isUsablePersonalKey("dev_YOUR_KEY_HERE"))
    @Test fun configuredKeyIsAccepted() = assertTrue(VisionViewModel.isUsablePersonalKey("dev_configured_key"))
    @Test fun initializingStateIsExplicit() = assertTrue(VisionUiState().status == ModelStatus.INITIALIZING)
    @Test fun suggestionsMatchPhotoQuestions() = assertTrue(VisionViewModel.suggestions.size == 4)
    @Test fun imageIsBoundedTo512px() = assertTrue(ImageDecoder.scaledSize(2048, 1024) == ImageDecoder.ImageSize(512, 256))
    @Test fun smallImageKeepsDimensions() = assertTrue(ImageDecoder.scaledSize(100, 200) == ImageDecoder.ImageSize(100, 200))
}
