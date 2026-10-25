package com.fqapp.fqapp;

import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.mockConstruction;
import static org.mockito.Mockito.mockStatic;
import static org.mockito.Mockito.verify;

import android.os.Handler;
import android.os.Looper;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import java.util.Collections;
import java.util.Map;
import org.junit.Test;
import org.mockito.MockedConstruction;
import org.mockito.MockedStatic;

/**
 * 分屏手势通道的分发边界：没有 Activity 时必须回 null（Dart 侧显示「暂不
 * 可用」），参数缺失必须报 INVALID_ARGUMENT 而不是崩溃。
 */
public class NativePlayerGestureTest {
    private interface PluginCheck {
        void run(NativePlayerPlugin plugin);
    }

    /** 插件构造时 new Handler(Looper.getMainLooper())，JVM 单测里要替换掉。 */
    private void withPlugin(PluginCheck check) {
        try (MockedStatic<Looper> loopers = mockStatic(Looper.class);
             MockedConstruction<Handler> handlers = mockConstruction(Handler.class)) {
            loopers.when(Looper::getMainLooper).thenReturn(mock(Looper.class));
            check.run(new NativePlayerPlugin());
        }
    }

    @Test
    public void gestureLevelsWithoutActivityReturnsNull() {
        withPlugin(plugin -> {
            MethodChannel.Result result = mock(MethodChannel.Result.class);

            plugin.onMethodCall(new MethodCall("gestureLevels", null), result);

            verify(result).success(null);
        });
    }

    @Test
    public void setScreenBrightnessRequiresAValue() {
        withPlugin(plugin -> {
            MethodChannel.Result result = mock(MethodChannel.Result.class);

            plugin.onMethodCall(
                    new MethodCall("setScreenBrightness", Collections.emptyMap()), result);

            verify(result).error(
                    "INVALID_ARGUMENT", "Missing required argument: value", null);
        });
    }

    @Test
    public void setMediaVolumeRequiresAValue() {
        withPlugin(plugin -> {
            MethodChannel.Result result = mock(MethodChannel.Result.class);

            plugin.onMethodCall(
                    new MethodCall("setMediaVolume", Collections.emptyMap()), result);

            verify(result).error(
                    "INVALID_ARGUMENT", "Missing required argument: value", null);
        });
    }

    @Test
    public void setScreenBrightnessWithoutActivityIsANoOp() {
        withPlugin(plugin -> {
            MethodChannel.Result result = mock(MethodChannel.Result.class);

            plugin.onMethodCall(
                    new MethodCall("setScreenBrightness", Map.of("value", 0.4)), result);

            verify(result).success(null);
        });
    }

    @Test
    public void resetWithoutAPriorOverrideIsANoOp() {
        withPlugin(plugin -> {
            MethodChannel.Result result = mock(MethodChannel.Result.class);

            plugin.onMethodCall(new MethodCall("resetScreenBrightness", null), result);

            verify(result).success(null);
        });
    }

    @Test
    public void setMediaVolumeWithoutActivityIsANoOp() {
        withPlugin(plugin -> {
            MethodChannel.Result result = mock(MethodChannel.Result.class);

            plugin.onMethodCall(new MethodCall("setMediaVolume", Map.of("value", 0.5)), result);

            verify(result).success(null);
        });
    }
}
