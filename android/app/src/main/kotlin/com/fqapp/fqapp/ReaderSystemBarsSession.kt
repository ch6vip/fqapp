package com.fqapp.fqapp

// Note: SDK 36 keeps edge-to-edge layout while the reader hides system bars.
// See .agents/notes/implemented/bug-fix/2026-10-12-reader-system-bars.md.
class ReaderSystemBarsSession {
    data class State(val visibleTypes: Int, val behavior: Int, val cutoutMode: Int? = null)

    interface Window {
        fun snapshot(): State
        fun hide(showStatusBar: Boolean)
        fun restore(state: State)
    }

    private var window: Window? = null
    private var original: State? = null
    private var owner: String? = null
    private var showStatusBar = false

    fun attach(window: Window) {
        detach()
        this.window = window
        reapply()
    }

    fun detach() {
        restore()
        window = null
    }

    fun open(session: String, showStatusBar: Boolean = false) {
        owner = session
        this.showStatusBar = showStatusBar
        reapply()
    }

    fun close(session: String) {
        if (owner != session) return
        clear()
    }

    fun clear() {
        restore()
        owner = null
    }

    fun reapply() {
        if (owner == null) return
        val target = window ?: return
        if (original == null) original = target.snapshot()
        target.hide(showStatusBar)
    }

    private fun restore() {
        original?.let { window?.restore(it) }
        original = null
    }
}
