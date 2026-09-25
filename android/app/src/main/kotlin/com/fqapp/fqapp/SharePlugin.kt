package com.fqapp.fqapp

import android.content.Context
import android.content.Intent
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 系统分享桥（官方用 `Intent.ACTION_SEND` + `text/plain`，
 * 见 com.dragon.read.base.share2.utils.m0 的系统分享分支）。
 *
 * 只做一件事：把标题+正文交给系统选择器。没有可分享的应用时返回 false，
 * Dart 侧会降级为「复制链接」并提示，而不是假装分享成功。
 */
class SharePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private var context: Context? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "fqapp/share")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        context = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "shareText") {
            result.notImplemented()
            return
        }
        val ctx = context
        if (ctx == null) {
            result.success(false)
            return
        }
        val title = call.argument<String>("title").orEmpty()
        val text = call.argument<String>("text").orEmpty()
        val send = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_SUBJECT, title)
            putExtra(Intent.EXTRA_TEXT, text)
        }
        val chooser = Intent.createChooser(send, title).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        try {
            ctx.startActivity(chooser)
            result.success(true)
        } catch (error: Exception) {
            result.success(false)
        }
    }
}
