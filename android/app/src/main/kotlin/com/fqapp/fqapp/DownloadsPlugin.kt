package com.fqapp.fqapp

import android.content.ContentResolver
import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import java.util.concurrent.Executors

/**
 * 平台导出通道（`fqapp/downloads`）：把一段纯文本写成系统「下载」目录里的 .txt。
 *
 * Android 10（API 29）起走 `MediaStore.Downloads`：不需要任何存储权限，
 * 文件在文件管理器的「下载」里直接可见；API 29 之前没有免权限的公共目录写法，
 * 落到应用自己的外部目录并回报 `public = false`，让 Dart 侧说清文件到底在哪，
 * 而不是谎报已经写进「下载」。
 *
 * 大书正文（整本可能十几 MB）不落在主线程上：写入在单线程池里做，结果回主线程。
 */
class DownloadsPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private var context: Context? = null
    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "fqapp/downloads")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        context = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "saveText") {
            result.notImplemented()
            return
        }
        val ctx = context
        if (ctx == null) {
            result.error("no_context", "导出通道未附着到引擎", null)
            return
        }
        val fileName = sanitize(call.argument<String>("fileName").orEmpty())
        val text = call.argument<String>("text").orEmpty()
        io.execute {
            val answer = try {
                save(ctx, fileName, text)
            } catch (error: Exception) {
                null
            }
            main.post {
                if (answer == null) {
                    result.error("write_failed", "无法写入系统下载目录", null)
                } else {
                    result.success(answer)
                }
            }
        }
    }

    private fun save(ctx: Context, fileName: String, text: String): Map<String, Any> {
        val bytes = text.toByteArray(Charsets.UTF_8)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val resolver = ctx.contentResolver
            val pending = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
                put(MediaStore.MediaColumns.MIME_TYPE, "text/plain")
                put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val uri: Uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, pending)
                ?: throw IOException("MediaStore 拒绝了导出条目")
            try {
                val out = resolver.openOutputStream(uri, "w")
                    ?: throw IOException("无法打开导出目标")
                out.use {
                    it.write(bytes)
                    it.flush()
                }
            } catch (error: Exception) {
                // A half-written pending row would show up as a broken file.
                resolver.delete(uri, null, null)
                throw error
            }
            resolver.update(
                uri,
                ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) },
                null,
                null,
            )
            // MediaStore 会为同名条目改名，所以回报的是登记后的真名。
            val stored = displayName(resolver, uri) ?: fileName
            val downloads = Environment.getExternalStoragePublicDirectory(
                Environment.DIRECTORY_DOWNLOADS,
            )
            return mapOf(
                "path" to "${downloads.absolutePath}/$stored",
                "public" to true,
            )
        }

        val directory = ctx.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
            ?: ctx.filesDir
        val file = File(directory, fileName)
        file.writeBytes(bytes)
        return mapOf("path" to file.absolutePath, "public" to false)
    }

    private fun displayName(resolver: ContentResolver, uri: Uri): String? = resolver.query(
        uri,
        arrayOf(MediaStore.MediaColumns.DISPLAY_NAME),
        null,
        null,
        null,
    )?.use { cursor -> if (cursor.moveToFirst()) cursor.getString(0) else null }

    /** 兜底清洗：路径分隔符绝不能进 DISPLAY_NAME；Dart 侧已做过一次同名折叠。 */
    private fun sanitize(raw: String): String {
        val name = raw.replace('/', '_').replace('\\', '_').trim()
        return name.ifEmpty { "book.txt" }
    }
}
