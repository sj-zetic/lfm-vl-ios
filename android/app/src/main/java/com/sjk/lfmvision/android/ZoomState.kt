package com.sjk.lfmvision.android

internal data class ZoomState(val scale: Float = 1f) {
    fun zoomBy(factor: Float) = copy(scale = (scale * factor).coerceIn(1f, 6f))
    fun doubleTap() = copy(scale = if (scale > 1f) 1f else 2.5f)
}
