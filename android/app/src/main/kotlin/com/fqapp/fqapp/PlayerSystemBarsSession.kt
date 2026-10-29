package com.fqapp.fqapp

// Note: SDK 36 keeps edge-to-edge while the player hides the system bars.
// Flutter's SystemUiMode.immersiveSticky only sets legacy system UI visibility
// flags, which Android 15+ ignores for target SDK 35+, so the fullscreen
// player goes through WindowInsetsController here instead. Same approach as
// ReaderSystemBarsSession.
class PlayerSystemBarsSession {
    data class State(val visibleTypes: Int, val behavior: Int, val cutoutMode: Int? = null)

    interface Window {
        fun snapshot(): State
        fun hide()
        fun restore(state: State)
    }

    private var window: Window? = null
    private var original: State? = null
    private var hidden = false

    fun attach(window: Window) {
        detach()
        this.window = window
        reapply()
    }

    fun detach() {
        restore()
        window = null
    }

    fun hide() {
        hidden = true
        applyHide()
    }

    fun show() {
        hidden = false
        restore()
    }

    fun clear() {
        hidden = false
        restore()
    }

    fun reapply() {
        if (hidden) applyHide()
    }

    private fun applyHide() {
        val target = window ?: return
        // Snapshot once per hidden window; repeated calls must not overwrite
        // the state captured before the first hide.
        if (original == null) original = target.snapshot()
        target.hide()
    }

    private fun restore() {
        val state = original ?: return
        original = null
        window?.restore(state)
    }
}
