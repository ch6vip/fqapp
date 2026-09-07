package com.fqapp.fqapp

import android.media.AudioManager
import android.view.Window
import kotlin.math.roundToInt

/** Window brightness is temporary; media volume follows the hardware keys. */
class NativePlaybackControls(
    private val window: Window,
    private val audio: AudioManager,
    private val systemBrightness: () -> Float
) {
    private var activeSession: Int? = null
    private var originalBrightness: Float? = null

    fun begin(session: Int): Map<String, Double> {
        close()
        originalBrightness = window.attributes.screenBrightness
        activeSession = session
        return read(session)
    }

    fun read(session: Int): Map<String, Double> {
        requireSession(session)
        val brightnessOverride = window.attributes.screenBrightness
        val brightness = if (brightnessOverride.isFinite() && brightnessOverride >= 0) brightnessOverride
            else systemBrightness()
        return mapOf(
            "brightness" to brightness.coerceIn(.05f, 1f).toDouble(),
            "volume" to mediaVolume()
        )
    }

    fun setBrightness(session: Int, value: Double): Double {
        requireSession(session)
        require(value.isFinite()) { "Invalid brightness" }
        val attributes = window.attributes
        attributes.screenBrightness = value.coerceIn(.05, 1.0).toFloat()
        window.attributes = attributes
        return attributes.screenBrightness.toDouble()
    }

    fun setVolume(session: Int, value: Double): Double {
        requireSession(session)
        require(value.isFinite()) { "Invalid volume" }
        val maximum = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        check(!audio.isVolumeFixed && maximum > 0) { "Media volume is fixed" }
        val index = (value.coerceIn(0.0, 1.0) * maximum).roundToInt()
        audio.setStreamVolume(AudioManager.STREAM_MUSIC, index, 0)
        // Android may limit the requested volume for the current output device.
        return mediaVolume()
    }

    fun end(session: Int) {
        if (activeSession == session) close()
    }

    fun close() {
        val original = originalBrightness
        activeSession = null
        originalBrightness = null
        if (original != null) {
            val attributes = window.attributes
            attributes.screenBrightness = original
            window.attributes = attributes
        }
    }

    private fun requireSession(session: Int) {
        check(activeSession == session) { "Playback controls session has ended" }
    }

    private fun mediaVolume(): Double {
        val maximum = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        return if (maximum <= 0) 0.0 else
            (audio.getStreamVolume(AudioManager.STREAM_MUSIC).toDouble() / maximum)
                .coerceIn(0.0, 1.0)
    }
}
