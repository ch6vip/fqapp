package com.fqapp.fqapp

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

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
    MethodChannel.MethodCallHandler,
    PluginRegistry.RequestPermissionsResultListener {
    private lateinit var channel: MethodChannel
    private var appContext: Context? = null
    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var pendingNotificationResult: MethodChannel.Result? = null
    private var notificationPermissionRequested = false
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
        activityBinding = binding
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        activityBinding = binding
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivity() {
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
        activity = null
        pendingNotificationResult?.success(false)
        pendingNotificationResult = null
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != NOTIFICATION_PERMISSION_REQUEST) return false
        val pending = pendingNotificationResult
        pendingNotificationResult = null
        val granted =
            grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
        pending?.success(granted)
        return true
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
            "updateNotification" -> {
                val text = call.argument<String>("text")
                if (text != null) {
                    AiRequestServiceRegistry.updateNotification(text)
                }
                result.success(null)
            }
            "requestNotifications" -> requestNotificationPermission(result)
            else -> result.notImplemented()
        }
    }

    private fun requestNotificationPermission(result: MethodChannel.Result) {
        val currentActivity = activity
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            currentActivity == null ||
            currentActivity.applicationInfo.targetSdkVersion < Build.VERSION_CODES.TIRAMISU
        ) {
            result.success(true)
            return
        }
        if (ContextCompat.checkSelfPermission(
                currentActivity,
                Manifest.permission.POST_NOTIFICATIONS
            ) == PackageManager.PERMISSION_GRANTED
        ) {
            result.success(true)
            return
        }
        if (notificationPermissionRequested) {
            result.success(false)
            return
        }
        notificationPermissionRequested = true
        pendingNotificationResult = result
        try {
            ActivityCompat.requestPermissions(
                currentActivity,
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                NOTIFICATION_PERMISSION_REQUEST,
            )
        } catch (error: Throwable) {
            notificationPermissionRequested = false
            pendingNotificationResult = null
            result.error("PERMISSION_REQUEST_FAILED", error.message, null)
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

    private companion object {
        const val NOTIFICATION_PERMISSION_REQUEST = 7413
    }
}
