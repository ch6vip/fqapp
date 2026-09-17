package com.fqapp.fqapp;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.mockConstruction;
import static org.mockito.Mockito.mockStatic;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.view.TextureRegistry;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import org.junit.Test;
import org.mockito.MockedConstruction;
import org.mockito.MockedStatic;

public class NativePlayerPluginTest {
    @Test
    public void cancelledCreationCannotAllocateAfterAllDelayedCallbacksExpire() {
        List<Runnable> queued = new ArrayList<>();
        List<Runnable> delayed = new ArrayList<>();
        try (MockedStatic<Looper> loopers = mockStatic(Looper.class);
             MockedConstruction<Handler> handlers = mockConstruction(Handler.class, (handler, ignored) -> {
                 when(handler.post(any(Runnable.class))).thenAnswer(call -> {
                     queued.add(call.getArgument(0));
                     return true;
                 });
                 when(handler.postDelayed(any(Runnable.class), anyLong())).thenAnswer(call -> {
                     delayed.add(call.getArgument(0));
                     return true;
                 });
             })) {
            loopers.when(Looper::getMainLooper).thenReturn(mock(Looper.class));
            FlutterPlugin.FlutterPluginBinding binding = mock(FlutterPlugin.FlutterPluginBinding.class);
            TextureRegistry textures = mock(TextureRegistry.class);
            when(binding.getBinaryMessenger()).thenReturn(mock(BinaryMessenger.class));
            when(binding.getTextureRegistry()).thenReturn(textures);
            when(binding.getApplicationContext()).thenReturn(mock(Context.class));
            NativePlayerPlugin plugin = new NativePlayerPlugin();
            plugin.onAttachedToEngine(binding);
            try {
                MethodChannel.Result created = mock(MethodChannel.Result.class);
                plugin.onMethodCall(new MethodCall("create", Map.of(
                        "cdnUrl", "https://example.invalid/video.mp4", "keyHex", "")), created);
                verify(created).success(Map.of("playerId", 1, "textureId", -1));
                plugin.onMethodCall(new MethodCall("dispose", Map.of("id", 1)),
                        mock(MethodChannel.Result.class));

                // Model a stalled create callback that returns after every
                // disposal timer has fired, without waiting in wall-clock time.
                for (Runnable callback : List.copyOf(delayed)) callback.run();
                for (Runnable callback : List.copyOf(queued)) callback.run();
                verify(textures, never()).createSurfaceProducer();
            } finally {
                plugin.onDetachedFromEngine(binding);
            }
        }
    }
}
