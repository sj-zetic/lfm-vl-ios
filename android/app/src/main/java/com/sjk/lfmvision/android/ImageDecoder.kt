package com.sjk.lfmvision.android

import android.content.ContentResolver
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.net.Uri
import androidx.exifinterface.media.ExifInterface
import com.zeticai.mlange.core.model.llm.ZeticMLangeLLMModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlin.math.max
import kotlin.math.roundToInt

object ImageDecoder {
    data class DecodedImage(
        val modelImage: ZeticMLangeLLMModel.Image,
        val preview: Bitmap,
    )

    suspend fun decode(contentResolver: ContentResolver, uri: Uri): DecodedImage =
        withContext(Dispatchers.IO) {
            val bitmap = contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it) }
                ?: error("이미지를 읽을 수 없습니다.")
            bitmap.useAsRgbImage(contentResolver.exifOrientation(uri))
        }

    private fun ContentResolver.exifOrientation(uri: Uri): Int =
        openInputStream(uri)?.use { ExifInterface(it).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL) }
            ?: ExifInterface.ORIENTATION_NORMAL

    private fun Bitmap.useAsRgbImage(orientation: Int): DecodedImage {
        val oriented = transformForOrientation(orientation)
        val size = scaledSize(oriented.width, oriented.height)
        val scaled = if (size.width == oriented.width && size.height == oriented.height) oriented else Bitmap.createScaledBitmap(oriented, size.width, size.height, true)
        return try {
            val pixels = IntArray(size.width * size.height)
            scaled.getPixels(pixels, 0, size.width, 0, 0, size.width, size.height)
            val rgb = ByteArray(size.width * size.height * RGB_CHANNELS)
            var outputIndex = 0
            pixels.forEach { pixel ->
                rgb[outputIndex++] = (pixel shr 16).toByte()
                rgb[outputIndex++] = (pixel shr 8).toByte()
                rgb[outputIndex++] = pixel.toByte()
            }
            DecodedImage(ZeticMLangeLLMModel.Image(rgb, size.width, size.height), scaled)
        } catch (error: Throwable) {
            if (scaled !== oriented) scaled.recycle()
            if (oriented !== this) oriented.recycle()
            if (this !== scaled) recycle()
            throw error
        }.also {
            if (oriented !== scaled && oriented !== this) oriented.recycle()
            if (this !== scaled) recycle()
        }
    }

    private fun Bitmap.transformForOrientation(orientation: Int): Bitmap {
        val matrix = Matrix().apply {
            when (orientation) {
                ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> setScale(-1f, 1f)
                ExifInterface.ORIENTATION_ROTATE_180 -> setRotate(180f)
                ExifInterface.ORIENTATION_FLIP_VERTICAL -> setScale(1f, -1f)
                ExifInterface.ORIENTATION_TRANSPOSE -> { setRotate(90f); postScale(-1f, 1f) }
                ExifInterface.ORIENTATION_ROTATE_90 -> setRotate(90f)
                ExifInterface.ORIENTATION_TRANSVERSE -> { setRotate(-90f); postScale(-1f, 1f) }
                ExifInterface.ORIENTATION_ROTATE_270 -> setRotate(-90f)
                else -> return this@transformForOrientation
            }
        }
        return Bitmap.createBitmap(this, 0, 0, width, height, matrix, true)
    }

    internal fun scaledSize(width: Int, height: Int): ImageSize {
        val scale = minOf(1f, MAX_SIZE.toFloat() / max(width, height).toFloat())
        return ImageSize((width * scale).roundToInt().coerceAtLeast(1), (height * scale).roundToInt().coerceAtLeast(1))
    }

    internal data class ImageSize(val width: Int, val height: Int)

    private const val MAX_SIZE = 512
    private const val RGB_CHANNELS = 3
}
