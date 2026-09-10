package com.fqapp.fqapp

/** Window ownership also guards against a departing reader's delayed cleanup. */
class ReaderBrightnessSession {
    interface Window {
        var brightness: Float
    }

    private var window: Window? = null
    private var original: Float? = null
    private var owner: String? = null
    private var value = -1f
    private var suspended = false

    fun attach(window: Window) {
        detach()
        this.window = window
        apply()
    }

    fun detach() {
        restore()
        window = null
        original = null
    }

    fun open(session: String, brightness: Float) {
        owner = session
        value = brightness
        suspended = false
        apply()
    }

    fun update(session: String, brightness: Float): Boolean {
        if (owner != session) return false
        value = brightness
        apply()
        return true
    }

    fun suspend(session: String) {
        if (owner != session) return
        suspended = true
        restore()
    }

    fun close(session: String) {
        if (owner != session) return
        restore()
        owner = null
        original = null
    }

    fun clear() {
        restore()
        owner = null
        original = null
    }

    private fun apply() {
        if (owner == null || suspended) return
        val target = window ?: return
        if (original == null) original = target.brightness
        target.brightness = value
    }

    private fun restore() {
        val saved = original ?: return
        window?.brightness = saved
    }
}
