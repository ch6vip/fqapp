package com.fqapp.fqapp

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "fqapp/backend"

        // 每次启动尝试的自增代号，进程级共享：Activity 重建后新实例继续用
        // 同一计数器，滞留的旧轮询线程才能识别自己已过期，避免把新一次
        // 启动的后端误杀掉。
        private val startAttempts = AtomicInteger(0)
    }

    private lateinit var native: BackendNativeApi

    //JNI 调用可能阻塞（如 Go 运行时冷启动、等待在途请求排空的 Shutdown），
    // 统统丢到线程池；stop/status 与 start 的轮询可并发，故不用单线程池。
    private val executor by lazy { Executors.newCachedThreadPool() }

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
                    val attempt = startAttempts.incrementAndGet()
                    executor.execute {
                        try {
                            native.startBackend(config, pool, filter)
                            // JNI 冷启动本身可能超过 deadline，轮询从调用返回后
                            // 重新计时，且至少读一次状态再判定。
                            var st = native.status()
                            val deadline = System.currentTimeMillis() + 15_000
                            while (st == "starting" && System.currentTimeMillis() < deadline) {
                                Thread.sleep(200)
                                st = native.status()
                            }
                            // CAS 认领停止权：若期间已有更新的启动尝试，计数器
                            // 已被抬高，这里必然失败，旧线程就不会误杀新后端。
                            if (st == "starting" && startAttempts.compareAndSet(attempt, attempt + 1)) {
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
                    }
                }
                "stopBackend" -> executor.execute {
                    try {
                        native.stopBackend()
                        runOnUiThread { result.success(null) }
                    } catch (e: Throwable) {
                        runOnUiThread {
                            result.error("JNI_STOP_ERROR", e.message ?: e.javaClass.simpleName, null)
                        }
                    }
                }
                "status" -> executor.execute {
                    try {
                        val st = native.status()
                        runOnUiThread { result.success(st) }
                    } catch (e: Throwable) {
                        runOnUiThread {
                            result.error("JNI_STATUS_ERROR", e.message ?: e.javaClass.simpleName, null)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        // Activity 重建时结束本实例的线程池：旧轮询线程随即被中断，不会再用
        // 陈旧的实例状态调用 JNI 去干涉新实例的后端启动。
        executor.shutdownNow()
        super.onDestroy()
    }
}
