package com.fqapp.fqapp;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.doAnswer;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.mockConstruction;
import static org.mockito.Mockito.mockStatic;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

import android.content.Context;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.view.Surface;
import androidx.media3.common.MediaItem;
import androidx.media3.common.PlaybackException;
import androidx.media3.common.Player;
import androidx.media3.datasource.DataSource;
import androidx.media3.datasource.DataSpec;
import androidx.media3.exoplayer.ExoPlayer;
import androidx.media3.exoplayer.source.ProgressiveMediaSource;
import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.view.TextureRegistry;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Queue;
import java.util.concurrent.ConcurrentLinkedQueue;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import org.junit.Test;
import org.mockito.MockedConstruction;
import org.mockito.MockedStatic;

public class NativePlayerCreationTest {
    private static final String URL = "https://example.invalid/video.mp4";
    private static final String KEY = "00112233445566778899aabbccddeeff";

    private static final class Fixture implements AutoCloseable {
        final Queue<Runnable> posted = new ConcurrentLinkedQueue<>();
        final List<Map<?, ?>> events = new ArrayList<>();
        final List<DataSource.Factory> dataSources = new ArrayList<>();
        final List<Player.Listener> listeners = new ArrayList<>();
        final CryptoStream stream = mock(CryptoStream.class);
        final ExoPlayer player = mock(ExoPlayer.class);
        final TextureRegistry textures = mock(TextureRegistry.class);
        final TextureRegistry.SurfaceProducer producer = mock(TextureRegistry.SurfaceProducer.class);
        final FlutterPlugin.FlutterPluginBinding binding = mock(FlutterPlugin.FlutterPluginBinding.class);
        final Uri uri = mock(Uri.class);
        final EventChannel.EventSink sink = mock(EventChannel.EventSink.class);
        final MockedStatic<Looper> loopers;
        final MockedStatic<Uri> uris;
        final MockedConstruction<Handler> handlers;
        final MockedConstruction<EventChannel> eventChannels;
        final MockedConstruction<ProgressiveMediaSource.Factory> mediaFactories;
        final NativePlayerPlugin plugin;

        Fixture() {
            loopers = mockStatic(Looper.class);
            loopers.when(Looper::getMainLooper).thenReturn(mock(Looper.class));
            uris = mockStatic(Uri.class);
            uris.when(() -> Uri.parse(anyString())).thenReturn(uri);
            handlers = mockConstruction(Handler.class, (handler, ignored) -> {
                when(handler.post(any(Runnable.class))).thenAnswer(call -> {
                    posted.add(call.getArgument(0));
                    return true;
                });
            });
            eventChannels = mockConstruction(EventChannel.class, (channel, ignored) -> {
                doAnswer(call -> {
                    EventChannel.StreamHandler handler = call.getArgument(0);
                    if (handler != null) handler.onListen(null, sink);
                    return null;
                }).when(channel).setStreamHandler(any());
            });
            mediaFactories = mockConstruction(ProgressiveMediaSource.Factory.class, (factory, construction) -> {
                dataSources.add((DataSource.Factory) construction.arguments().get(0));
                when(factory.createMediaSource(any(MediaItem.class)))
                        .thenReturn(mock(ProgressiveMediaSource.class));
            });
            doAnswer(call -> {
                events.add((Map<?, ?>) call.getArgument(0));
                return null;
            }).when(sink).success(any());
            doAnswer(call -> {
                listeners.add(call.getArgument(0));
                return null;
            }).when(player).addListener(any());
            when(binding.getBinaryMessenger()).thenReturn(mock(BinaryMessenger.class));
            when(binding.getTextureRegistry()).thenReturn(textures);
            when(binding.getApplicationContext()).thenReturn(mock(Context.class));
            when(textures.createSurfaceProducer()).thenReturn(producer);
            when(producer.getSurface()).thenReturn(mock(Surface.class));
            when(producer.id()).thenReturn(23L);
            when(stream.open(URL, KEY)).thenReturn(7L);
            when(stream.size(7L)).thenReturn(100L);
            plugin = new NativePlayerPlugin(stream, context -> player);
            plugin.onAttachedToEngine(binding);
        }

        void create(String key) {
            MethodChannel.Result result = mock(MethodChannel.Result.class);
            plugin.onMethodCall(new MethodCall("create", Map.of("cdnUrl", URL, "keyHex", key)), result);
            verify(result).success(Map.of("playerId", 1, "textureId", -1));
        }

        void dispose() {
            plugin.onMethodCall(new MethodCall("dispose", Map.of("id", 1)), mock(MethodChannel.Result.class));
        }

        void drain() {
            for (int i = 0; i < 100; i++) {
                Runnable next = posted.poll();
                if (next == null) return;
                next.run();
            }
            throw new AssertionError("Unexpected unbounded main-thread callbacks");
        }

        List<Object> eventTypes() {
            List<Object> types = new ArrayList<>();
            for (Map<?, ?> event : events) types.add(event.get("type"));
            return types;
        }

        @Override
        public void close() {
            try {
                plugin.onDetachedFromEngine(binding);
                drain();
            } finally {
                mediaFactories.close();
                eventChannels.close();
                handlers.close();
                uris.close();
                loopers.close();
            }
        }
    }

    @Test
    public void encryptedCreationDefersItsOnlyOpenUntilTheMediaDataSourceLoads() throws Exception {
        CountDownLatch allowOpen = new CountDownLatch(1);
        try (Fixture f = new Fixture()) {
            when(f.stream.open(URL, KEY)).thenAnswer(call -> {
                assertTrue("test open did not get released", allowOpen.await(5, TimeUnit.SECONDS));
                return 7L;
            });
            try {
                f.create(KEY);
                f.drain();
                assertEquals(List.of("created"), f.eventTypes());
                verify(f.player).prepare();
                verify(f.stream).ensureInitialized();
                verify(f.stream, never()).open(anyString(), anyString());

                allowOpen.countDown();
                DataSource source = f.dataSources.get(0).createDataSource();
                assertEquals(100L, source.open(new DataSpec.Builder().setUri(f.uri).build()));
                source.close();
                verify(f.stream, times(1)).open(URL, KEY);
                verify(f.stream, times(1)).close(7L);
            } finally {
                allowOpen.countDown();
            }
        }
    }

    @Test
    public void cancelledEncryptedCreationDoesNotOpenOrAllocateOutput() {
        try (Fixture f = new Fixture()) {
            f.create(KEY);
            f.dispose();
            f.drain();
            verify(f.stream, never()).open(anyString(), anyString());
            verifyNoInteractions(f.player, f.textures);
            assertTrue(f.events.isEmpty());
        }
    }

    @Test
    public void initializationFailureReportsAnErrorWithoutAllocatingAPlayer() {
        try (Fixture f = new Fixture()) {
            doThrow(new IllegalStateException("crypto library unavailable")).when(f.stream).ensureInitialized();
            f.create(KEY);
            f.drain();
            assertEquals(List.of("error"), f.eventTypes());
            assertEquals("Player creation failed",
                    ((Map<?, ?>) f.events.get(0).get("value")).get("message"));
            verifyNoInteractions(f.player, f.textures);
            verify(f.stream, never()).open(anyString(), anyString());
        }
    }

    @Test
    public void sourceErrorsBeforeAndAfterCreatedRemainObservableAndDisposable() {
        for (boolean early : new boolean[] {true, false}) {
            try (Fixture f = new Fixture(); MockedStatic<SystemClock> clocks = mockStatic(SystemClock.class)) {
                PlaybackException error = new PlaybackException("source failed", null,
                        PlaybackException.ERROR_CODE_IO_UNSPECIFIED);
                if (early) {
                    doAnswer(call -> {
                        f.listeners.get(0).onPlayerError(error);
                        return null;
                    }).when(f.player).prepare();
                }
                f.create(KEY);
                f.drain();
                if (!early) {
                    f.listeners.get(0).onPlayerError(error);
                    f.drain();
                }
                assertEquals(early ? List.of("error", "created") : List.of("created", "error"), f.eventTypes());
                Map<?, ?> details = (Map<?, ?>) f.events.get(early ? 0 : 1).get("value");
                assertEquals(PlaybackException.ERROR_CODE_IO_UNSPECIFIED, details.get("errorCode"));
                f.dispose();
                f.dispose();
                verify(f.player, times(1)).release();
                verify(f.producer, times(1)).release();
            }
        }
    }

    @Test
    public void prepareFailureReleasesAllocatedOutputAndReportsOnlyAnError() {
        try (Fixture f = new Fixture()) {
            doThrow(new IllegalStateException("prepare failed")).when(f.player).prepare();
            f.create(KEY);
            f.drain();
            assertEquals(List.of("error"), f.eventTypes());
            verify(f.player).release();
            verify(f.producer).release();
        }
    }

    @Test
    public void plainCreationDoesNotInitializeOrOpenCrypto() {
        try (Fixture f = new Fixture()) {
            f.create("");
            f.drain();
            assertEquals(List.of("created"), f.eventTypes());
            verify(f.player).setMediaItem(any(MediaItem.class));
            verify(f.player).prepare();
            verifyNoInteractions(f.stream);
        }
    }
}
