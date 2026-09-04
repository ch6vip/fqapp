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

        // BackendNative loads liblegacy.so in its init block. If the .so is
        // missing or has no JNI exports (e.g. the old placeholder copy), this
        // throws UnsatisfiedLinkError and we catch it so the Flutter side can
        // fall back to Process.start.
        native = try {
            BackendNative()
        } catch (e: UnsatisfiedLinkError) {
            android.util.Log.w("MainActivity", "JNI backend unavailable, will use Process.start fallback", e)
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
                        } catch (e: Exception) {
                            runOnUiThread {
                                result.error("JNI_ERROR", e.message, null)
                            }
                        }
                    }.start()
                }
                "stopBackend" -> {
                    native.stopBackend()
                    result.success(null)
                }
                "status" -> {
                    result.success(native.status())
                }
                else -> result.notImplemented()
            }
        }
    }
}
