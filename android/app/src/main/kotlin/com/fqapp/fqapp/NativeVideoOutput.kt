package com.fqapp.fqapp

import android.view.Surface
import androidx.media3.common.Player
import io.flutter.view.TextureRegistry

/** Owns the decoder and its Flutter-managed output surface on the platform thread. */
internal class NativeVideoOutput(
    private val player: Player,
    private val producer: TextureRegistry.SurfaceProducer
) : TextureRegistry.SurfaceProducer.Callback {
    private var released = false
    private var needsSurface = true
    private var surfaceTextureEntry: TextureRegistry.SurfaceTextureEntry? = null
    private var surfaceTextureSurface: Surface? = null
    private var swapped = false

    val textureId: Long get() = surfaceTextureEntry?.id() ?: producer.id()

    fun attach() {
        if (released || swapped) return
        producer.setCallback(this)
        onSurfaceAvailable()
    }

    override fun onSurfaceAvailable() {
        if (released || swapped || !needsSurface) return
        // A restored producer may return a different Surface. Never keep the
        // Surface returned before cleanup or bind it back to the decoder.
        player.setVideoSurface(producer.surface)
        needsSurface = false
    }

    override fun onSurfaceCleanup() {
        if (released || swapped || needsSurface) return
        needsSurface = true
        player.clearVideoSurface()
    }

    /**
     * Moves decoder output from the ImageReader producer to a legacy
     * SurfaceTexture entry. Only the SurfaceTexture path applies the decoder
     * crop rect: the ImageReader producer draws the whole allocation,
     * including stride padding, as a green bar on software decoders (#2).
     * Returns the new texture id, or null when already swapped. The caller
     * must forward the id to Dart so it rebuilds its Texture widget.
     * The old producer is released only after the player has moved to the
     * new surface, so the decoder never writes to a released surface. When
     * creation of the new surface fails, the old output stays untouched.
     */
    fun swapToSurfaceTexture(
        textureRegistry: TextureRegistry
    ): Long? {
        if (released || swapped) return null
        val entry = textureRegistry.createSurfaceTexture()
        val surface = Surface(entry.surfaceTexture())
        try {
            player.setVideoSurface(surface)
        } catch (error: Throwable) {
            try {
                surface.release()
            } catch (_: Throwable) {
            }
            try {
                entry.release()
            } catch (_: Throwable) {
            }
            throw error
        }
        try {
            producer.setCallback(null)
        } catch (_: Throwable) {
        }
        try {
            producer.release()
        } catch (_: Throwable) {
        }
        surfaceTextureEntry = entry
        surfaceTextureSurface = surface
        swapped = true
        return entry.id()
    }

    fun rotationCorrection(formatRotationDegrees: Int): Int =
        if (swapped) 0
        else if (!producer.handlesCropAndRotation() &&
            formatRotationDegrees in listOf(90, 180, 270)
        ) formatRotationDegrees else 0

    /** 诊断用：producer 是否已代劳裁剪与旋转（决定上面那条分支）。 */
    fun handlesCropAndRotation(): Boolean =
        swapped || producer.handlesCropAndRotation()

    fun release() {
        if (released) return
        released = true
        try {
            if (!swapped) producer.setCallback(null)
        } finally {
            // The decoder must stop writing before Flutter releases the
            // surface. The producer owns Surface.release(), including cleanup.
            try {
                player.release()
            } finally {
                if (swapped) {
                    try {
                        surfaceTextureSurface?.release()
                    } finally {
                        surfaceTextureEntry?.release()
                    }
                } else {
                    producer.release()
                }
            }
        }
    }
}
