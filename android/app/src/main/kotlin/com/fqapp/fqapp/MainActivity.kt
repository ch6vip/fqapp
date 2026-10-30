package com.fqapp.fqapp

import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterShellArgs
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    // 音量键翻页桥。Dart 侧在阅读页且开启“音量键翻页”时通过 setEnabled(true)
    // 通知原生拦截音量键，原生 dispatchKeyEvent 吃掉按键（系统音量不再变化）并通过
    // volumeKey 回调让 Dart 翻页。该方案在原生层拦截，不受 Flutter 生命周期
    // 过渡事件漏发导致的 HardwareKeyboard 派发丢失影响。
    private var volumeKeyEnabled = false
    private var volumeChannel: MethodChannel? = null

    override fun getFlutterShellArgs(): FlutterShellArgs = super.getFlutterShellArgs().also {
        // Runs before the engine/FlutterLoader starts; configureFlutterEngine is
        // too late to select the process-wide rendering backend.
        RendererCompatibility.configure(it)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Native ExoPlayer host for DRM short dramas (CENC streaming decrypt).
        flutterEngine.plugins.add(NativePlayerPlugin())
        flutterEngine.plugins.add(ReaderDevicePlugin())
        // 全屏播放用 WindowInsetsController 隐藏系统栏；immersiveSticky 在
        // target SDK 36 的 edge-to-edge 下已不生效（issue #176）。
        flutterEngine.plugins.add(PlayerSystemUiPlugin())
        flutterEngine.plugins.add(SystemTtsPlugin())
        flutterEngine.plugins.add(LocalBookPickerPlugin())
        flutterEngine.plugins.add(LibraryBackupPlugin())
        flutterEngine.plugins.add(FanqieAccountPlugin())
        // 官方系统分享是 Intent.ACTION_SEND；没有可分享的应用时回 false。
        flutterEngine.plugins.add(SharePlugin())
        // 整本 TXT 导出：MediaStore.Downloads 或应用外部目录，见 DownloadsPlugin。
        flutterEngine.plugins.add(DownloadsPlugin())
        // 海信墨水屏整屏刷新（压残影）：反射调用厂商 EPD 接口。
        flutterEngine.plugins.add(EinkRefreshPlugin())
        // 小米澎湃 OS 公平运行内存：收 TRIM/KILL 广播，转发 Dart 处理后回系统。
        flutterEngine.plugins.add(FairMemoryPlugin())

        // 音量键翻页通道：Dart -> 原生 setEnabled 控制是否拦截；原生 -> Dart
        // volumeKey 回调翻页方向（+1 下一页 / -1 上一页）。
        volumeChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "fqapp/volume-key",
        ).also { ch ->
            ch.setMethodCallHandler { call, result ->
                when (call.method) {
                    "setEnabled" -> {
                        volumeKeyEnabled = call.arguments as? Boolean ?: false
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun dispatchKeyEvent(event: KeyEvent?): Boolean {
        if (volumeKeyEnabled && event != null) {
            val key = event.keyCode
            if (key == KeyEvent.KEYCODE_VOLUME_DOWN || key == KeyEvent.KEYCODE_VOLUME_UP) {
                // 仅在首次按下（非长按重复）触发一次翻页，避免按住连翻。
                if (event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) {
                    val direction = if (key == KeyEvent.KEYCODE_VOLUME_DOWN) 1 else -1
                    volumeChannel?.invokeMethod("volumeKey", direction)
                }
                // 无论按下/抬起都吃掉音量键，系统音量面板不再弹出。
                return true
            }
        }
        return super.dispatchKeyEvent(event)
    }
}
