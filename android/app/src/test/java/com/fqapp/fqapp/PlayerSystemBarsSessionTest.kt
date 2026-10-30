package com.fqapp.fqapp

import org.junit.Assert.assertEquals
import org.junit.Test

class PlayerSystemBarsSessionTest {
    private class Window(
        var state: PlayerSystemBarsSession.State = PlayerSystemBarsSession.State(3, 1, 0),
    ) : PlayerSystemBarsSession.Window {
        var snapshots = 0
        var hides = 0
        var restores = 0

        override fun snapshot(): PlayerSystemBarsSession.State {
            snapshots++
            return state
        }

        override fun hide() {
            hides++
            state = PlayerSystemBarsSession.State(0, 2, state.cutoutMode?.let { 3 })
        }

        override fun restore(state: PlayerSystemBarsSession.State) {
            this.state = state
            restores++
        }
    }

    @Test fun hideBeforeAttachAppliesWhenTheActivityArrives() {
        val session = PlayerSystemBarsSession()
        session.hide()
        val window = Window()
        session.attach(window)
        assertEquals(0, window.state.visibleTypes)
        assertEquals(3, window.state.cutoutMode)
        assertEquals(1, window.hides)
    }

    @Test fun repeatedHideSnapshotsOnce() {
        val session = PlayerSystemBarsSession()
        val window = Window()
        session.attach(window)
        session.hide()
        session.hide()
        assertEquals(1, window.snapshots)
        assertEquals(2, window.hides)
        assertEquals(0, window.state.visibleTypes)
    }

    @Test fun showRestoresTheCapturedStateOnlyOnce() {
        val session = PlayerSystemBarsSession()
        val window = Window()
        val original = window.state
        session.attach(window)
        session.hide()
        session.show()
        assertEquals(original, window.state)
        assertEquals(1, window.restores)
        session.show()
        assertEquals(1, window.restores)
    }

    @Test fun focusGainRehidesWithoutOverwritingTheOriginalState() {
        val session = PlayerSystemBarsSession()
        val window = Window()
        val original = window.state
        session.attach(window)
        session.hide()
        window.state = original // The OS restored the bars on focus gain.
        session.reapply()
        assertEquals(0, window.state.visibleTypes)
        assertEquals(1, window.snapshots)
        session.show()
        assertEquals(original, window.state)
    }

    @Test fun activityRecreationKeepsTheHiddenRequestAndEachWindowsOwnState() {
        val session = PlayerSystemBarsSession()
        val first = Window()
        session.attach(first)
        session.hide()
        session.detach()
        assertEquals(PlayerSystemBarsSession.State(3, 1, 0), first.state)
        val second = Window(PlayerSystemBarsSession.State(2, 0, 2))
        session.attach(second)
        assertEquals(0, second.state.visibleTypes)
        assertEquals(3, second.state.cutoutMode)
        session.show()
        assertEquals(PlayerSystemBarsSession.State(2, 0, 2), second.state)
    }

    @Test fun showBeforeReattachDoesNotHideTheNextWindow() {
        val session = PlayerSystemBarsSession()
        val first = Window()
        session.attach(first)
        session.hide()
        session.show()
        session.detach()
        val second = Window()
        session.attach(second)
        assertEquals(PlayerSystemBarsSession.State(3, 1, 0), second.state)
        assertEquals(0, second.hides)
    }

    @Test fun clearForgetsTheHiddenRequest() {
        val session = PlayerSystemBarsSession()
        val window = Window()
        val original = window.state
        session.attach(window)
        session.hide()
        session.clear()
        assertEquals(original, window.state)
        val next = Window()
        session.attach(next)
        assertEquals(original, next.state)
        assertEquals(0, next.hides)
    }
}
