package com.fqapp.fqapp

import android.view.Surface
import androidx.media3.common.Player
import io.flutter.view.TextureRegistry

/**
 * Owns the decoder and its Flutter-managed output surface on the platform thread.
 *
 * Two surface moves share this class and must not step on each other:
 *
 * - [swapped] — the software-decoder path from #2: decoder output moves once
 *   from the ImageReader producer to a legacy SurfaceTexture entry so the
 *   decoder's crop rect applies instead of drawing stride padding as a green
 *   bar.
 * - [floating] — the #24 background floating window: the decoder temporarily
 *   renders to the overlay's SurfaceView and comes back to whichever Flutter
 *   surface is current when playback returns.
 */
internal class NativeVideoOutput(
    private val player: Player,
    private val producer: TextureRegistry.SurfaceProducer
) : TextureRegistry.SurfaceProducer.Callback {
    private var released = false
    private var needsSurface = true
    private var surfaceTextureEntry: TextureRegistry.SurfaceTextureEntry? = null
    private var surfaceTextureSurface: Surface? = null
    private var swapped = false

    /**
     * True while the decoder renders to the floating overlay instead of the
     * Flutter texture. While floating, producer callbacks must not clear the
     * overlay surface; they only record that the Flutter surface needs a
     * rebind when playback returns.
     */
    private var floating = false

    val textureId: Long
        get() = surfaceTextureEntry?.id() ?: producer.id()

    fun attach() {
        if (released || swapped) return
        producer.setCallback(this)
        onSurfaceAvailable()
    }

    override fun onSurfaceAvailable() {
        if (released || swapped || floating || !needsSurface) return
        // A restored producer may return a different Surface. Never keep the
        // Surface returned before cleanup or bind it back to the decoder.
        player.setVideoSurface(producer.surface)
        needsSurface = false
    }

    override fun onSurfaceCleanup() {
        if (released) return
        if (swapped) {
            if (needsSurface) return
            needsSurface = true
            player.clearVideoSurface()
            return
        }
        val wasNeeding = needsSurface
        needsSurface = true
        // While floating the overlay owns the surface; only remember that the
        // Flutter side will need a rebind later.
        if (floating || wasNeeding) return
        player.clearVideoSurface()
    }

    /** Detach the Flutter texture so the decoder can render to the floating overlay. */
    fun detachForFloating() {
        if (released) return
        floating = true
        if (!swapped) needsSurface = true
        player.clearVideoSurface()
    }

    /** Bind the decoder to the floating overlay's surface. */
    fun attachFloating(surface: Surface) {
        if (released) return
        player.setVideoSurface(surface)
    }

    /**
     * Return the decoder to the Flutter texture. If the Flutter surface was
     * cleaned up while floating, [needsSurface] stays true and the next
     * [onSurfaceAvailable] rebinds it; otherwise rebind immediately.
     */
    fun restoreFromFloating() {
        if (released) return
        floating = false
        player.clearVideoSurface()
        // After a #2 swap the current Flutter surface is the SurfaceTexture
        // entry, not the producer.
        if (needsSurface) return
        if (swapped) {
            surfaceTextureSurface?.let { player.setVideoSurface(it) }
        } else {
            player.setVideoSurface(producer.surface)
        }
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
