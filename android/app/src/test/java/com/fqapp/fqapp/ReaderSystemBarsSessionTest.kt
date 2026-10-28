package com.fqapp.fqapp

import org.junit.Assert.assertEquals
import org.junit.Test

class ReaderSystemBarsSessionTest {
    private class Window(var state: ReaderSystemBarsSession.State = ReaderSystemBarsSession.State(3, 1, 0)) :
        ReaderSystemBarsSession.Window {
        var restores = 0
        override fun snapshot() = state
        override fun hide(showStatusBar: Boolean) {
            state = ReaderSystemBarsSession.State(if (showStatusBar) 1 else 0, 2, state.cutoutMode?.let { 3 })
        }
        override fun restore(state: ReaderSystemBarsSession.State) {
            this.state = state
            restores++
        }
    }

    @Test fun repeatedEntryAndFocusRestoreTheOriginalBarsAndCutoutMode() {
        val session = ReaderSystemBarsSession()
        val window = Window()
        val original = window.state
        session.attach(window)
        session.open("reader")
        session.open("reader")
        window.state = original // The OS/Flutter restored bars on focus gain.
        session.reapply()
        assertEquals(0, window.state.visibleTypes)
        assertEquals(3, window.state.cutoutMode)
        session.close("reader")
        assertEquals(original, window.state)
        assertEquals(1, window.restores)
        session.reapply()
        assertEquals(original, window.state)
    }

    @Test fun statusBarToggleKeepsNavigationHiddenAndRestoresOriginalState() {
        val session = ReaderSystemBarsSession()
        val window = Window()
        val original = window.state
        session.attach(window)
        session.open("reader", true)
        assertEquals(1, window.state.visibleTypes)
        session.open("reader", false)
        assertEquals(0, window.state.visibleTypes)
        session.open("reader", true)
        window.state = original
        session.reapply()
        assertEquals(1, window.state.visibleTypes)
        session.close("reader")
        assertEquals(original, window.state)
        assertEquals(1, window.restores)
    }

    @Test fun visibleStatusBarSurvivesActivityRecreation() {
        val session = ReaderSystemBarsSession()
        val first = Window()
        session.attach(first)
        session.open("reader", true)
        session.detach()
        assertEquals(ReaderSystemBarsSession.State(3, 1, 0), first.state)
        val second = Window(ReaderSystemBarsSession.State(2, 0, 2))
        session.attach(second)
        assertEquals(1, second.state.visibleTypes)
        session.close("reader")
        assertEquals(ReaderSystemBarsSession.State(2, 0, 2), second.state)
    }

    @Test fun aDepartingReaderCannotRestoreOverTheNextReader() {
        val session = ReaderSystemBarsSession()
        val window = Window()
        val original = window.state
        session.attach(window)
        session.open("old")
        session.open("new")
        session.close("old")
        assertEquals(0, window.state.visibleTypes)
        assertEquals(0, window.restores)
        session.close("new")
        assertEquals(original, window.state)
    }

    @Test fun activityRecreationRestoresEachWindowsOwnState() {
        val session = ReaderSystemBarsSession()
        val first = Window()
        session.attach(first)
        session.open("reader")
        session.detach()
        assertEquals(ReaderSystemBarsSession.State(3, 1, 0), first.state)
        val second = Window(ReaderSystemBarsSession.State(2, 0, 2))
        session.attach(second)
        assertEquals(0, second.state.visibleTypes)
        session.clear()
        assertEquals(ReaderSystemBarsSession.State(2, 0, 2), second.state)
    }

    @Test fun closingWhileDetachedDoesNotHideBarsOnReattach() {
        val session = ReaderSystemBarsSession()
        session.attach(Window())
        session.open("reader")
        session.detach()
        session.close("reader")
        val next = Window()
        session.attach(next)
        assertEquals(ReaderSystemBarsSession.State(3, 1, 0), next.state)
    }
}
