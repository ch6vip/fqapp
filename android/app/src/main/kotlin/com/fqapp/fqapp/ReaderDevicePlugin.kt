package com.fqapp.fqapp

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.os.BatteryManager
import android.view.WindowManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.provider.Settings
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.Executors

// Note: Window-only brightness and system status broadcasts; see
// .agents/notes/implemented/feature/2026-09-10-reader-interface.md
class ReaderDevicePlugin : FlutterPlugin, ActivityAware,
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler,
    PluginRegistry.ActivityResultListener {
    private lateinit var context: Context
    private lateinit var methods: MethodChannel
    private lateinit var events: EventChannel
    private var binding: ActivityPluginBinding? = null
    private var eventSink: EventChannel.EventSink? = null
    private var receiverRegistered = false
    private var session: String? = null
    private val brightness = ReaderBrightnessSession()
    private var pendingFont: MethodChannel.Result? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val filesExecutor = Executors.newSingleThreadExecutor()

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            emitStatus()
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methods = MethodChannel(binding.binaryMessenger, "fqapp/reader")
        events = EventChannel(binding.binaryMessenger, "fqapp/reader/events")
        methods.setMethodCallHandler(this)
        events.setStreamHandler(this)
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        this.binding = binding
        binding.addActivityResultListener(this)
        val window = binding.activity.window
        brightness.attach(object : ReaderBrightnessSession.Window {
            override var brightness: Float
                get() = window.attributes.screenBrightness
                set(value) {
                    val attributes = window.attributes
                    attributes.screenBrightness = value
                    window.attributes = attributes
                }
        })
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivityForConfigChanges() {
        brightness.detach()
        binding?.removeActivityResultListener(this)
        binding = null
    }

    override fun onDetachedFromActivity() {
        brightness.clear()
        session = null
        cancelFontPicker()
        onDetachedFromActivityForConfigChanges()
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        onDetachedFromActivity()
        onCancel(null)
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        filesExecutor.shutdownNow()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "pickFont") {
            pickFont(result)
            return
        }
        if (call.method == "keepScreenOn") {
            val window = binding?.activity?.window
            if (window == null) {
                result.error("NO_ACTIVITY", "阅读界面尚未就绪", null)
                return
            }
            if (call.argument<Boolean>("on") == true) {
                window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            } else {
                window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            }
            result.success(true)
            return
        }
        val id = call.argument<String>("session")
        if (id.isNullOrEmpty()) {
            result.error("BAD_SESSION", "阅读会话已结束", null)
            return
        }
        when (call.method) {
            "start", "setBrightness" -> {
                if (binding == null) {
                    result.error("NO_ACTIVITY", "阅读界面尚未就绪", null)
                    return
                }
                val raw = call.argument<Number>("brightness")?.toFloat()
                if (raw == null || !raw.isFinite() || (raw != -1f && raw !in 0.02f..1f)) {
                    result.error("BAD_BRIGHTNESS", "亮度值无效", null)
                    return
                }
                if (call.method == "start") {
                    session = id
                    brightness.open(id, raw)
                    result.success(snapshot())
                    emitStatus()
                } else {
                    result.success(brightness.update(id, raw))
                }
            }
            "suspend" -> {
                brightness.suspend(id)
                result.success(null)
            }
            "stop" -> {
                brightness.close(id)
                if (session == id) session = null
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
        eventSink = sink
        if (!receiverRegistered) {
            val filter = IntentFilter().apply {
                addAction(Intent.ACTION_BATTERY_CHANGED)
                addAction(Intent.ACTION_TIME_TICK)
                addAction(Intent.ACTION_TIME_CHANGED)
                addAction(Intent.ACTION_TIMEZONE_CHANGED)
            }
            if (Build.VERSION.SDK_INT >= 33) {
                context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                @Suppress("DEPRECATION")
                context.registerReceiver(receiver, filter)
            }
            receiverRegistered = true
        }
        emitStatus()
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
        if (receiverRegistered) {
            context.unregisterReceiver(receiver)
            receiverRegistered = false
        }
    }

    private fun emitStatus() {
        if (session != null) eventSink?.success(snapshot())
    }

    private fun snapshot(): Map<String, Any?> {
        val battery = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val level = battery?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = battery?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
        val plugged = battery?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0
        val systemBrightness = runCatching {
            Settings.System.getInt(context.contentResolver, Settings.System.SCREEN_BRIGHTNESS) / 255.0
        }.getOrNull()
        return mapOf(
            "session" to session,
            "timestamp" to System.currentTimeMillis(),
            "battery" to if (level >= 0 && scale > 0) (level * 100 / scale).coerceIn(0, 100) else null,
            "charging" to (plugged != 0),
            "systemBrightness" to systemBrightness
        )
    }

    private fun pickFont(result: MethodChannel.Result) {
        val activity = binding?.activity
        if (activity == null || pendingFont != null) {
            result.error("FONT_PICKER_BUSY", "请先关闭已打开的字体选择器", null)
            return
        }
        pendingFont = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(Intent.EXTRA_MIME_TYPES, arrayOf(
                "font/ttf", "font/otf", "font/collection", "application/x-font-ttf",
                "application/x-font-opentype", "application/font-sfnt", "application/octet-stream"
            ))
        }
        try {
            @Suppress("DEPRECATION")
            activity.startActivityForResult(intent, FONT_REQUEST)
        } catch (_: Exception) {
            pendingFont = null
            result.error("FONT_PICKER_UNAVAILABLE", "无法打开文件选择器", null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != FONT_REQUEST) return false
        val result = pendingFont ?: return true
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            pendingFont = null
            result.success(null)
            return true
        }
        filesExecutor.execute {
            val imported = runCatching { importFont(uri) }
            mainHandler.post {
                if (pendingFont === result) {
                    pendingFont = null
                    imported.fold(
                        onSuccess = { result.success(it) },
                        onFailure = { result.error("FONT_IMPORT_FAILED", it.message ?: "字体导入失败", null) }
                    )
                }
            }
        }
        return true
    }

    private fun importFont(uri: Uri): Map<String, String> {
        val resolver = context.contentResolver
        val name = resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
            if (it.moveToFirst()) it.getString(0)?.take(120) else null
        } ?: "自定义字体"
        val directory = File(context.filesDir, "reader-fonts").apply { mkdirs() }
        val temporary = File.createTempFile("import-", ".tmp", directory)
        try {
            val digest = MessageDigest.getInstance("SHA-256")
            resolver.openInputStream(uri)?.use { input ->
                temporary.outputStream().use { output ->
                    val buffer = ByteArray(16 * 1024)
                    var total = 0L
                    while (true) {
                        if (Thread.currentThread().isInterrupted) error("字体导入已取消")
                        val count = input.read(buffer)
                        if (count < 0) break
                        total += count
                        require(total <= 32 * 1024 * 1024) { "请选择小于 32 MB 的字体文件" }
                        digest.update(buffer, 0, count)
                        output.write(buffer, 0, count)
                    }
                }
            } ?: error("无法读取这个字体文件")
            require(temporary.length() >= 12) { "字体文件不完整" }
            val header = temporary.inputStream().use { input -> ByteArray(4).also { input.read(it) } }
            val signature = header.joinToString("") { "%02x".format(it.toInt() and 0xff) }
            require(signature in setOf("00010000", "4f54544f", "74746366", "74727565")) {
                "请选择 TTF、OTF 或 TTC 字体文件"
            }
            val hash = digest.digest().joinToString("") { "%02x".format(it.toInt() and 0xff) }
            val target = File(directory, "$hash.font")
            if (!target.exists()) check(temporary.renameTo(target)) { "无法保存字体文件" }
            pruneImportedFonts(directory, target)
            return mapOf("path" to target.absolutePath, "name" to name)
        } finally {
            temporary.delete()
        }
    }

    private fun cancelFontPicker() {
        pendingFont?.error("READER_CLOSED", "阅读界面已关闭", null)
        pendingFont = null
    }

    // 导入字体按内容寻址，历史文件不会自动消失；仅保留最近导入的少量
    // 字体，删除更旧的 .font 文件，避免 app 私有存储随导入次数无限增长。
    private fun pruneImportedFonts(directory: File, keep: File) {
        val files = directory.listFiles()?.filter { it.isFile && it.name.endsWith(".font") } ?: return
        files.asSequence()
            .filter { it != keep }
            .sortedByDescending { it.lastModified() }
            .drop(MAX_RETAINED_FONTS - 1)
            .forEach { it.delete() }
    }

    companion object {
        private const val FONT_REQUEST = 0x4651
        private const val MAX_RETAINED_FONTS = 4
    }
}
