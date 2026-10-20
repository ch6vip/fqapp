package com.fqapp.fqapp

import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

// Note: 海信墨水屏整屏刷新（压残影）。通过反射调用厂商私有 EPD 接口
// com.hmct.epd.EpdManager.forceClear()，参考 Hisense-E-Ink-auto-refresh 项目
// 的 Utils.refreshScreen。通道 fqapp/eink-refresh。
class EinkRefreshPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var context: Context
    private lateinit var methods: MethodChannel

    // 解析一次后缓存，避免每页翻页都做反射；解析失败保持 null 表示不支持。
    private var epdForceClear: java.lang.reflect.Method? = null
    private var epdSupported: Boolean? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methods = MethodChannel(binding.binaryMessenger, "fqapp/eink-refresh")
        methods.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods.setMethodCallHandler(null)
        epdForceClear = null
        epdSupported = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isSupported" -> result.success(isSupported())
            "refresh" -> result.success(refresh())
            else -> result.notImplemented()
        }
    }

    private fun isSupported(): Boolean {
        if (epdSupported != null) return epdSupported == true
        epdSupported = runCatching { resolveForceClear() != null }.getOrDefault(false)
        return epdSupported == true
    }

    /// 解析海信 EPD 的全刷方法；返回 null 表示本设备没有该接口（非海信墨水屏）。
    private fun resolveForceClear(): java.lang.reflect.Method? {
        if (epdForceClear != null) return epdForceClear
        epdForceClear = runCatching {
            Class.forName("com.hmct.epd.EpdManager")
                .getMethod("forceClear")
        }.getOrNull()
        return epdForceClear
    }

    /// 调用一次整屏全刷压残影。成功返回 true；设备不支持或调用异常返回 false。
    private fun refresh(): Boolean {
        val method = resolveForceClear() ?: return false
        return runCatching {
            val service = context.getSystemService("epd")
            method.invoke(service)
            true
        }.getOrDefault(false)
    }
}
