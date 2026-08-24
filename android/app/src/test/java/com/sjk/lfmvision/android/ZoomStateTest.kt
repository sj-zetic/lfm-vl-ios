package com.sjk.lfmvision.android

import org.junit.Assert.assertEquals
import org.junit.Test

class ZoomStateTest {
    @Test fun zoomIsClampedAndDoubleTapToggles() {
        assertEquals(6f, ZoomState().zoomBy(20f).scale)
        assertEquals(2.5f, ZoomState().doubleTap().scale)
        assertEquals(1f, ZoomState(2.5f).doubleTap().scale)
    }

    @Test fun transcriptTargetAccountsForPreviewItems() {
        assertEquals(1, firstTurnIndex(false))
        assertEquals(2, firstTurnIndex(true))
    }
}
