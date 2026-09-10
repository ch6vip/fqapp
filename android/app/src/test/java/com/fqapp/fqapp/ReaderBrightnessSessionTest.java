package com.fqapp.fqapp;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import org.junit.Test;

public class ReaderBrightnessSessionTest {
    private static class FakeWindow implements ReaderBrightnessSession.Window {
        float value;
        FakeWindow(float value) { this.value = value; }
        @Override public float getBrightness() { return value; }
        @Override public void setBrightness(float value) { this.value = value; }
    }

    @Test public void manualAndSystemModesRestoreThePreexistingWindowValue() {
        ReaderBrightnessSession session = new ReaderBrightnessSession();
        FakeWindow window = new FakeWindow(0.42f);
        session.attach(window);
        session.open("reader", 0.18f);
        assertEquals(0.18f, window.value, 0.0001f);
        session.update("reader", -1f);
        assertEquals(-1f, window.value, 0.0001f);
        session.close("reader");
        assertEquals(0.42f, window.value, 0.0001f);
    }

    @Test public void delayedCleanupCannotOverrideANewerReader() {
        ReaderBrightnessSession session = new ReaderBrightnessSession();
        FakeWindow window = new FakeWindow(-1f);
        session.attach(window);
        session.open("old", 0.2f);
        session.open("new", 0.7f);
        session.close("old");
        session.suspend("old");
        assertFalse(session.update("old", 0.9f));
        assertEquals(0.7f, window.value, 0.0001f);
        session.close("new");
        assertEquals(-1f, window.value, 0.0001f);
    }

    @Test public void backgroundingRestoresBrightnessUntilTheReaderResumes() {
        ReaderBrightnessSession session = new ReaderBrightnessSession();
        FakeWindow window = new FakeWindow(-1f);
        session.attach(window);
        session.open("reader", 0.2f);
        session.suspend("reader");
        assertEquals(-1f, window.value, 0.0001f);
        session.update("reader", 0.3f);
        assertEquals(-1f, window.value, 0.0001f);
        session.open("reader", 0.3f);
        assertEquals(0.3f, window.value, 0.0001f);
        session.clear();
        assertEquals(-1f, window.value, 0.0001f);
    }

    @Test public void activityRecreationRestoresBothWindowsIndependently() {
        ReaderBrightnessSession session = new ReaderBrightnessSession();
        FakeWindow first = new FakeWindow(0.4f);
        FakeWindow second = new FakeWindow(0.8f);
        session.attach(first);
        session.open("reader", 0.2f);
        session.detach();
        assertEquals(0.4f, first.value, 0.0001f);
        session.attach(second);
        assertEquals(0.2f, second.value, 0.0001f);
        session.close("reader");
        assertEquals(0.8f, second.value, 0.0001f);
    }
}
