package com.fqapp.fqapp

import androidx.media3.common.Player
import io.flutter.view.TextureRegistry

/** Owns the decoder and its Flutter-managed output surface on the platform thread. */
internal class NativeVideoOutput(
    private val player: Player,
    private val producer: TextureRegistry.SurfaceProducer
) : TextureRegistry.SurfaceProducer.Callback {
    private var released = false
    private var needsSurface = true

    val textureId: Long get() = producer.id()

    fun attach() {
        if (released) return
        producer.setCallback(this)
        onSurfaceAvailable()
    }

    override fun onSurfaceAvailable() {
        if (released || !needsSurface) return
        // A restored producer may return a different Surface. Never keep the
        // Surface returned before cleanup or bind it back to the decoder.
        player.setVideoSurface(producer.surface)
        needsSurface = false
    }

    override fun onSurfaceCleanup() {
        if (released || needsSurface) return
        needsSurface = true
        player.clearVideoSurface()
    }

    fun rotationCorrection(formatRotationDegrees: Int): Int =
        if (!producer.handlesCropAndRotation() &&
            formatRotationDegrees in listOf(90, 180, 270)
        ) formatRotationDegrees else 0

    fun release() {
        if (released) return
        released = true
        try {
            producer.setCallback(null)
        } finally {
            // The decoder must stop writing before Flutter releases the
            // surface. The producer owns Surface.release(), including cleanup.
            try {
                player.release()
            } finally {
                producer.release()
            }
        }
    }
}
