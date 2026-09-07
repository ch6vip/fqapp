package com.fqapp.fqapp;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertThrows;
import static org.mockito.Mockito.clearInvocations;
import static org.mockito.Mockito.doAnswer;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

import android.media.AudioManager;
import android.view.Window;
import android.view.WindowManager;
import org.junit.Before;
import org.junit.Test;

public class NativePlaybackControlsTest {
    private Window window;
    private WindowManager.LayoutParams attributes;
    private AudioManager audio;
    private NativePlaybackControls controls;

    @Before
    public void setUp() {
        window = mock(Window.class);
        attributes = mock(WindowManager.LayoutParams.class);
        attributes.screenBrightness = -1f;
        when(window.getAttributes()).thenReturn(attributes);
        audio = mock(AudioManager.class);
        when(audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)).thenReturn(15);
        when(audio.getStreamVolume(AudioManager.STREAM_MUSIC)).thenReturn(6);
        controls = new NativePlaybackControls(window, audio, () -> .6f);
    }

    @Test
    public void temporaryBrightnessIsClampedAndRestoresAutomaticMode() {
        assertEquals(.6, controls.begin(1).get("brightness"), .0001);
        assertEquals(.05, controls.setBrightness(1, -3), .0001);
        assertEquals(1, controls.setBrightness(1, 4), .0001);
        controls.end(1);
        assertEquals(-1f, attributes.screenBrightness, 0f);
        clearInvocations(window, audio);
        controls.close();
        verifyNoInteractions(window, audio);
    }

    @Test
    public void existingWindowOverrideIsRestoredExactly() {
        attributes.screenBrightness = .37f;
        controls.begin(1);
        controls.setBrightness(1, .9);
        controls.close();
        assertEquals(.37f, attributes.screenBrightness, 0f);
    }

    @Test
    public void oldSessionCannotChangeOrReleaseTheNewSession() {
        controls.begin(1);
        controls.setBrightness(1, .8);
        controls.begin(2);
        controls.setBrightness(2, .4);
        controls.end(1);
        assertEquals(.4f, attributes.screenBrightness, .0001f);
        assertThrows(IllegalStateException.class, () -> controls.setBrightness(1, .9));
        assertThrows(IllegalStateException.class, () -> controls.setVolume(1, 1));
        controls.end(2);
        assertEquals(-1f, attributes.screenBrightness, 0f);
    }

    @Test
    public void readsReflectHardwareVolumeChangesAndWritesReportAndroidLimits() {
        assertEquals(.4, controls.begin(1).get("volume"), .0001);
        when(audio.getStreamVolume(AudioManager.STREAM_MUSIC)).thenReturn(3);
        assertEquals(.2, controls.read(1).get("volume"), .0001);
        doAnswer(invocation -> {
            when(audio.getStreamVolume(AudioManager.STREAM_MUSIC)).thenReturn(10);
            return null;
        }).when(audio).setStreamVolume(AudioManager.STREAM_MUSIC, 15, 0);
        assertEquals(10.0 / 15, controls.setVolume(1, 3), .0001);
        verify(audio).setStreamVolume(AudioManager.STREAM_MUSIC, 15, 0);
        controls.setVolume(1, -2);
        verify(audio).setStreamVolume(AudioManager.STREAM_MUSIC, 0, 0);
        clearInvocations(audio);
        controls.close();
        verifyNoInteractions(audio);
    }

    @Test
    public void fixedVolumeIsReportedWithoutBreakingBrightnessCleanup() {
        controls.begin(1);
        controls.setBrightness(1, .8);
        when(audio.isVolumeFixed()).thenReturn(true);
        assertThrows(IllegalStateException.class, () -> controls.setVolume(1, .9));
        verify(audio, never()).setStreamVolume(AudioManager.STREAM_MUSIC, 14, 0);
        controls.close();
        assertEquals(-1f, attributes.screenBrightness, 0f);
    }

    @Test
    public void nonFiniteLevelsAreRejectedBeforeTouchingTheDevice() {
        controls.begin(1);
        clearInvocations(window, audio);
        assertThrows(IllegalArgumentException.class, () -> controls.setBrightness(1, Double.NaN));
        assertThrows(IllegalArgumentException.class, () -> controls.setVolume(1, Double.POSITIVE_INFINITY));
        verifyNoInteractions(window, audio);
    }
}
