package com.fqapp.fqapp

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Parcel
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

// 小米澎湃 OS 公平运行内存适配（https://dev.mi.com/xiaomihyperos/documentation/detail?pId=2304）：
// 系统在应用内存触达预警线时发 TRIM 广播（释放内存），触达查杀线时发 KILL
// 广播（3 秒内保存现场数据），应用都必须通过广播里带的回调 Binder 回处理结果。
//
// 接线：原生只负责收广播、转发给 Dart、回系统；真正释放内存 / 保存进度由
// Dart 侧 FairMemoryService 做（图片缓存、阅读/播放进度都在 Dart 侧）。
// 只在小米设备上生效：其他系统永远不发这两个广播。
class FairMemoryPlugin : FlutterPlugin {
    private lateinit var context: Context
    private lateinit var channel: MethodChannel
    private val mainHandler = Handler(Looper.getMainLooper())
    private var receiverRegistered = false

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            val action = intent?.action ?: return
            val kind = when (action) {
                ACTION_TRIM -> KIND_TRIM
                ACTION_KILL -> KIND_KILL
                else -> return
            }
            val common = intent.extras?.getBundle(KEY_COMMON) ?: return
            val notifyType = common.getInt(KEY_NOTIFY_TYPE, 0)
            val notifyId = common.getInt(KEY_NOTIFY_ID, 0)
            val callback = common.getBinder(KEY_CALLBACK)
            if (callback == null) {
                // 文档行为：无回调 Binder 时只记日志，不回。
                Log.w(TAG, "公平运行内存广播缺少回调 Binder，跳过回复：$action")
                return
            }
            val replied = AtomicBoolean(false)
            // 系统端超时 3 秒；2.5 秒仍无 Dart 回应时按“未处理”回，避免系统侧挂死。
            val fallback = Runnable {
                reply(callback, notifyType, notifyId, RESULT_UNHANDLED, replied)
            }
            mainHandler.postDelayed(fallback, REPLY_TIMEOUT_MS)
            channel.invokeMethod(
                METHOD_ON_MEMORY_WARNING,
                mapOf(
                    "kind" to kind,
                    "notifyType" to notifyType,
                    "notifyId" to notifyId,
                ),
                object : MethodChannel.Result {
                    override fun success(result: Any?) {
                        mainHandler.removeCallbacks(fallback)
                        val handled = result as? Boolean ?: false
                        reply(
                            callback,
                            notifyType,
                            notifyId,
                            if (handled) RESULT_HANDLED else RESULT_UNHANDLED,
                            replied,
                        )
                    }

                    override fun error(code: String, message: String?, details: Any?) {
                        mainHandler.removeCallbacks(fallback)
                        reply(callback, notifyType, notifyId, RESULT_UNHANDLED, replied)
                    }

                    override fun notImplemented() {
                        mainHandler.removeCallbacks(fallback)
                        reply(callback, notifyType, notifyId, RESULT_UNHANDLED, replied)
                    }
                },
            )
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        val filter = IntentFilter().apply {
            addAction(ACTION_TRIM)
            addAction(ACTION_KILL)
        }
        // 广播由系统进程（应用外 UID）发出，Android 13+ 必须声明导出，文档示例
        // 同样用 RECEIVER_EXPORTED。收到的 Binder 只用于回当次通知，伪造广播
        // 最多触发一次缓存清理 / 进度保存，无敏感操作。
        if (Build.VERSION.SDK_INT >= 33) {
            context.registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            context.registerReceiver(receiver, filter)
        }
        receiverRegistered = true
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        if (receiverRegistered) {
            context.unregisterReceiver(receiver)
            receiverRegistered = false
        }
        mainHandler.removeCallbacksAndMessages(null)
    }

    private fun reply(
        callback: IBinder,
        notifyType: Int,
        notifyId: Int,
        result: Int,
        replied: AtomicBoolean,
    ) {
        // 兜底与 Dart 回应可能同时到达，只回一次。
        if (!replied.compareAndSet(false, true)) return
        val data = Parcel.obtain()
        val replyParcel = Parcel.obtain()
        try {
            data.writeInt(notifyType)
            data.writeInt(notifyId)
            data.writeInt(result)
            data.writeBundle(Bundle())
            callback.transact(
                TRANSACTION_EXCEPTION_REPLY,
                data,
                replyParcel,
                IBinder.FLAG_ONEWAY,
            )
            replyParcel.readException()
        } catch (e: Exception) {
            Log.e(TAG, "公平运行内存回调失败", e)
        } finally {
            replyParcel.recycle()
            data.recycle()
        }
    }

    companion object {
        private const val TAG = "FairMemory"
        private const val CHANNEL = "fqapp/fair_memory"
        private const val METHOD_ON_MEMORY_WARNING = "onMemoryWarning"
        private const val ACTION_TRIM = "itgsa.intent.action.TRIM"
        private const val ACTION_KILL = "itgsa.intent.action.KILL"
        private const val KIND_TRIM = "trim"
        private const val KIND_KILL = "kill"
        private const val KEY_COMMON = "common"
        private const val KEY_NOTIFY_TYPE = "notifyType"
        private const val KEY_NOTIFY_ID = "notifyId"
        private const val KEY_CALLBACK = "callback"
        private const val TRANSACTION_EXCEPTION_REPLY = IBinder.FIRST_CALL_TRANSACTION
        private const val RESULT_HANDLED = 0
        private const val RESULT_UNHANDLED = 1
        private const val REPLY_TIMEOUT_MS = 2500L
    }
}
