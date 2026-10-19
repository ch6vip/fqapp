package com.fqapp.fqapp;

import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.mockConstruction;
import static org.mockito.Mockito.mockStatic;
import static org.mockito.Mockito.when;

import android.os.Handler;
import android.os.Looper;
import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.BinaryMessenger;
import java.lang.reflect.Field;
import java.util.concurrent.ExecutorService;
import org.junit.Test;
import org.mockito.MockedConstruction;
import org.mockito.MockedStatic;

public class DownloadsPluginTest {
    @Test
    public void detachingFromEngineShutsDownTheIoExecutor() throws Exception {
        try (MockedStatic<Looper> loopers = mockStatic(Looper.class);
             MockedConstruction<Handler> handlers = mockConstruction(Handler.class)) {
            loopers.when(Looper::getMainLooper).thenReturn(mock(Looper.class));
            FlutterPlugin.FlutterPluginBinding binding =
                    mock(FlutterPlugin.FlutterPluginBinding.class);
            when(binding.getBinaryMessenger()).thenReturn(mock(BinaryMessenger.class));

            DownloadsPlugin plugin = new DownloadsPlugin();
            plugin.onAttachedToEngine(binding);

            Field ioField = DownloadsPlugin.class.getDeclaredField("io");
            ioField.setAccessible(true);
            ExecutorService io = (ExecutorService) ioField.get(plugin);
            assertFalse(io.isShutdown());

            plugin.onDetachedFromEngine(binding);
            assertTrue(io.isShutdown());
        }
    }
}
