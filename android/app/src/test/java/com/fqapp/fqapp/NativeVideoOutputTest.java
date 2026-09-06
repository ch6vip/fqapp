package com.fqapp.fqapp;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertThrows;
import static org.mockito.Mockito.clearInvocations;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.inOrder;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.verifyNoMoreInteractions;
import static org.mockito.Mockito.when;

import android.view.Surface;
import androidx.media3.common.Player;
import io.flutter.view.TextureRegistry;
import org.junit.Before;
import org.junit.Test;
import org.mockito.InOrder;

public class NativeVideoOutputTest {
    private Player player;
    private TextureRegistry.SurfaceProducer producer;
    private NativeVideoOutput output;
    private Surface firstSurface;
    private Surface restoredSurface;

    @Before
    public void setUp() {
        player = mock(Player.class);
        producer = mock(TextureRegistry.SurfaceProducer.class);
        firstSurface = mock(Surface.class);
        restoredSurface = mock(Surface.class);
        when(producer.getSurface()).thenReturn(firstSurface, restoredSurface);
        when(producer.id()).thenReturn(23L);
        output = new NativeVideoOutput(player, producer);
    }

    @Test
    public void duplicateAvailabilityKeepsTheExistingDecoderSurface() {
        output.attach();
        verify(producer).setCallback(output);
        verify(player).setVideoSurface(firstSurface);
        assertEquals(23L, output.getTextureId());
        clearInvocations(player, producer);

        output.onSurfaceAvailable();
        output.onSurfaceAvailable();
        verifyNoInteractions(player, producer);
    }

    @Test
    public void cleanupAndRestoreBindTheNewSurfaceWithoutRestartingPlayback() {
        output.attach();
        clearInvocations(player, producer);

        output.onSurfaceCleanup();
        output.onSurfaceCleanup();
        output.onSurfaceAvailable();
        output.onSurfaceAvailable();

        InOrder order = inOrder(player, producer);
        order.verify(player).clearVideoSurface();
        order.verify(producer).getSurface();
        order.verify(player).setVideoSurface(restoredSurface);
        verifyNoMoreInteractions(player, producer);
        verifyNoInteractions(firstSurface, restoredSurface);
    }

    @Test
    public void releaseStopsTheDecoderBeforeTheSurfaceAndIgnoresLateCallbacks() {
        output.attach();
        clearInvocations(player, producer);

        output.release();
        output.release();
        output.onSurfaceAvailable();
        output.onSurfaceCleanup();
        output.attach();

        InOrder order = inOrder(player, producer);
        order.verify(producer).setCallback(null);
        order.verify(player).release();
        order.verify(producer).release();
        verifyNoMoreInteractions(player, producer);
        verifyNoInteractions(firstSurface, restoredSurface);
    }

    @Test
    public void decoderReleaseFailureStillReleasesTheProducer() {
        output.attach();
        clearInvocations(player, producer);
        doThrow(new IllegalStateException("release failed")).when(player).release();

        assertThrows(IllegalStateException.class, output::release);
        output.release();
        output.onSurfaceAvailable();
        output.onSurfaceCleanup();

        verify(producer).setCallback(null);
        verify(player).release();
        verify(producer).release();
        verifyNoMoreInteractions(player, producer);
    }

    @Test
    public void failedInitialBindingCanReleaseBothAllocatedResources() {
        doThrow(new IllegalStateException("bind failed"))
                .when(player).setVideoSurface(firstSurface);
        assertThrows(IllegalStateException.class, output::attach);

        output.release();
        verify(player).release();
        verify(producer).release();
        verifyNoInteractions(firstSurface);
    }

    @Test
    public void rotationIsCorrectedOnlyForBackendsThatNeedIt() {
        when(producer.handlesCropAndRotation()).thenReturn(false);
        for (int rotation : new int[] {0, 90, 180, 270}) {
            assertEquals(rotation, output.rotationCorrection(rotation));
        }
        assertEquals(0, output.rotationCorrection(45));

        when(producer.handlesCropAndRotation()).thenReturn(true);
        for (int rotation : new int[] {0, 90, 180, 270}) {
            assertEquals(0, output.rotationCorrection(rotation));
        }
        verifyNoInteractions(player);
    }
}
