package com.fqapp.fqapp

import android.app.Activity
import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Dart bridge for the AI request foreground service.
 *
 * `acquire` returns only after the service has actually entered the
 * foreground state. A request must not start when this fails: otherwise the
 * UI would report progress for a request Android may freeze as soon as the
 * screen turns off.
 */
class AiRequestPlugin :
    FlutterPlugin,
    ActivityAware,
    MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private var appContext: Context? = null
    private var activity: Activity? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "fqapp/ai_request")
        channel.setMethodCallHandler(this)
        AiRequestServiceRegistry.listener = { reason ->
            mainHandler.post { channel.invokeMethod("serviceStopped", reason) }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        AiRequestServiceRegistry.listener = null
        channel.setMethodCallHandler(null)
        appContext = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "acquire" -> acquire(result)
            "release" -> {
                val leaseId = call.argument<String>("leaseId")
                if (leaseId == null) {
                    result.error("NO_LEASE", "缺少租约 ID", null)
                } else {
                    AiRequestServiceRegistry.release(leaseId)
                    result.success(null)
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun acquire(result: MethodChannel.Result) {
        val context = appContext
        if (context == null) {
            result.error("NO_CONTEXT", "应用上下文不可用", null)
            return
        }
        val resumed = (activity as? MainActivity)?.isResumed == true
        AiRequestServiceRegistry.acquire(context, resumed) { ok, message, leaseId ->
            mainHandler.post {
                if (ok && leaseId != null) {
                    result.success(leaseId)
                } else {
                    result.error("FOREGROUND_UNAVAILABLE", message ?: "无法启动前台服务", null)
                }
            }
        }
    }
}
