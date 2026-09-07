package com.fqapp.fqapp;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertThrows;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.clearInvocations;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import android.net.Uri;
import androidx.media3.common.C;
import androidx.media3.common.PlaybackException;
import androidx.media3.datasource.DataSourceException;
import androidx.media3.datasource.DataSpec;
import androidx.media3.datasource.TransferListener;
import java.io.EOFException;
import java.io.IOException;
import org.junit.Before;
import org.junit.Test;

public class CryptoDataSourceTest {
    private CryptoStream stream;
    private NativePlayerPlugin.CryptoDataSource source;
    private Uri uri;

    @Before
    public void setUp() {
        stream = mock(CryptoStream.class);
        when(stream.open("https://example.invalid/video.mp4", "key")).thenReturn(7L);
        when(stream.size(7L)).thenReturn(100L);
        when(stream.seek(eq(7L), anyLong())).thenAnswer(invocation -> invocation.getArgument(1));
        source = new NativePlayerPlugin.CryptoDataSource(
                "https://example.invalid/video.mp4", "key", stream);
        uri = mock(Uri.class);
    }

    private DataSpec request(long position, long length) {
        return new DataSpec.Builder().setUri(uri).setPosition(position).setLength(length).build();
    }

    @Test
    public void outOfRangePositionIsReportedAndTheOpenedHandleIsReleased() {
        DataSourceException error = assertThrows(DataSourceException.class,
                () -> source.open(request(101, C.LENGTH_UNSET)));
        assertEquals(PlaybackException.ERROR_CODE_IO_READ_POSITION_OUT_OF_RANGE, error.reason);
        verify(stream, never()).seek(eq(7L), anyLong());
        verify(stream).close(7L);
        assertNull(source.getUri());
        source.close();
        verify(stream, times(1)).close(7L);
    }

    @Test
    public void positionAtTheEndIsAnEmptySuccessfulReadWithoutSeeking() {
        assertEquals(0L, source.open(request(100, C.LENGTH_UNSET)));
        assertEquals(C.RESULT_END_OF_INPUT, source.read(new byte[10], 0, 10));
        verify(stream, never()).seek(eq(7L), anyLong());
        verify(stream, never()).read(eq(7L), any(byte[].class), anyInt());
        source.close();
    }

    @Test
    public void requestLengthIsLimitedToAvailableBytesAndStopsAtTheRealEnd() {
        assertEquals(20L, source.open(request(80, 50)));
        verify(stream).seek(7L, 80L);
        when(stream.read(eq(7L), any(byte[].class), eq(20))).thenReturn(20);
        assertEquals(20, source.read(new byte[100], 0, 100));
        assertEquals(C.RESULT_END_OF_INPUT, source.read(new byte[1], 0, 1));
        verify(stream, times(1)).read(eq(7L), any(byte[].class), anyInt());
        source.close();
    }

    @Test
    public void requestedSubrangeCanEndBeforeTheResourceDoes() {
        assertEquals(5L, source.open(request(80, 5)));
        when(stream.read(eq(7L), any(byte[].class), eq(5))).thenReturn(5);
        assertEquals(5, source.read(new byte[20], 0, 20));
        assertEquals(C.RESULT_END_OF_INPUT, source.read(new byte[1], 0, 1));
        source.close();
    }

    @Test
    public void shortNetworkReadMustNotBecomeACompletedEpisode() {
        for (int terminal : new int[] {0, -1}) {
            assertEquals(100L, source.open(request(0, C.LENGTH_UNSET)));
            when(stream.read(eq(7L), any(byte[].class), anyInt())).thenReturn(25, terminal);
            assertEquals(25, source.read(new byte[100], 0, 100));
            assertThrows(EOFException.class, () -> source.read(new byte[100], 0, 100));
            source.close();
        }
    }

    @Test
    public void explicitLengthStillDetectsTruncationWhenResourceSizeIsUnknown() {
        when(stream.size(7L)).thenReturn(-1L);
        assertEquals(10L, source.open(request(0, 10)));
        assertThrows(EOFException.class, () -> source.read(new byte[10], 0, 10));
        source.close();
    }

    @Test
    public void unboundedUnknownSizeRetainsNormalEofBehavior() {
        when(stream.size(7L)).thenReturn(-1L);
        assertEquals(C.LENGTH_UNSET, source.open(request(0, C.LENGTH_UNSET)));
        assertEquals(C.RESULT_END_OF_INPUT, source.read(new byte[10], 0, 10));
        source.close();
    }

    @Test
    public void openFailureReleasesItsHandleBeforeARetry() {
        when(stream.size(7L)).thenThrow(new IllegalStateException("native size failed"));
        assertThrows(IllegalStateException.class, () -> source.open(request(0, C.LENGTH_UNSET)));
        verify(stream).close(7L);
        clearInvocations(stream);
        source.close();
        verify(stream, never()).close(7L);
    }

    @Test
    public void aFailedOrInexactNativeSeekCannotServeBytesFromTheWrongOffset() {
        for (long actualPosition : new long[] {-1L, 0L, 79L, 81L}) {
            when(stream.seek(7L, 80L)).thenReturn(actualPosition);
            assertThrows(IOException.class, () -> source.open(request(80, 10)));
            verify(stream).close(7L);
            assertNull(source.getUri());
            verify(stream, never()).read(eq(7L), any(byte[].class), anyInt());
            clearInvocations(stream);
        }
    }

    @Test
    public void closeFailureStillBalancesTransferEventsAndCannotDoubleRelease() {
        TransferListener listener = mock(TransferListener.class);
        source.addTransferListener(listener);
        DataSpec request = request(0, C.LENGTH_UNSET);
        source.open(request);
        verify(listener).onTransferInitializing(source, request, true);
        verify(listener).onTransferStart(source, request, true);
        doThrow(new IllegalStateException("native close failed")).when(stream).close(7L);
        assertThrows(IllegalStateException.class, source::close);
        verify(listener).onTransferEnd(source, request, true);
        source.close();
        verify(stream, times(1)).close(7L);
    }
}
