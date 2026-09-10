package com.fqapp.fqapp

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "fqapp/backend"
    }

    private lateinit var native: BackendNativeApi

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Native ExoPlayer host for DRM short dramas (CENC streaming decrypt).
        flutterEngine.plugins.add(NativePlayerPlugin())
        flutterEngine.plugins.add(ReaderDevicePlugin())

        // BackendNative loads liblegacy.so in its init block. If the .so is
        // missing or has no JNI exports (e.g. the old placeholder copy), this
        // throws a LinkageError. Complete the channel with "unavailable" so
        // Flutter can report a bounded startup error instead of hanging.
        native = try {
            BackendNative()
        } catch (e: Throwable) {
            android.util.Log.w("MainActivity", "JNI backend unavailable", e)
            // A no-op stub so the channel handler still has a receiver; the
            // Flutter side detects the failure via status() returning "unavailable".
            object : BackendNativeApi {
                override fun startBackend(configPath: String, poolPath: String, filterPath: String) {}
                override fun stopBackend() {}
                override fun status(): String = "unavailable"
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startBackend" -> {
                    val config = call.argument<String>("config") ?: ""
                    val pool = call.argument<String>("pool") ?: ""
                    val filter = call.argument<String>("filter") ?: ""
                    // Run on a background thread so the JNI call never blocks
                    // the platform thread.
                    Thread {
                        try {
                            native.startBackend(config, pool, filter)
                            // Poll status until running or failed, up to 15s.
                            val deadline = System.currentTimeMillis() + 15_000
                            var st = "starting"
                            while (System.currentTimeMillis() < deadline && st == "starting") {
                                st = native.status()
                                if (st == "starting") Thread.sleep(200)
                            }
                            if (st == "starting") {
                                native.stopBackend()
                                st = "failed: JNI startup timeout"
                            }
                            runOnUiThread { result.success(st) }
                        } catch (e: Throwable) {
                            runOnUiThread {
                                result.error(
                                    "JNI_ERROR",
                                    e.message ?: e.javaClass.simpleName,
                                    null
                                )
                            }
                        }
                    }.start()
                }
                "stopBackend" -> {
                    try {
                        native.stopBackend()
                        result.success(null)
                    } catch (e: Throwable) {
                        result.error("JNI_STOP_ERROR", e.message ?: e.javaClass.simpleName, null)
                    }
                }
                "status" -> {
                    try {
                        result.success(native.status())
                    } catch (e: Throwable) {
                        result.error("JNI_STATUS_ERROR", e.message ?: e.javaClass.simpleName, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}
