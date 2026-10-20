package com.fqapp.fqapp

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

/** System-picked backups and credential-free, app-private library captures. */
class LibraryBackupPlugin : FlutterPlugin, ActivityAware,
    MethodChannel.MethodCallHandler, PluginRegistry.ActivityResultListener {
    private lateinit var appContext: android.content.Context
    private lateinit var channel: MethodChannel
    private var activityBinding: ActivityPluginBinding? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val ioExecutor = Executors.newSingleThreadExecutor()
    private data class Pending(
        val result: MethodChannel.Result,
        val requestCode: Int,
        val bytes: ByteArray?,
        val parts: List<String>? = null,
    )
    @Volatile private var pending: Pending? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "fqapp/library_backup")
        channel.setMethodCallHandler(this)
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addActivityResultListener(this)
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivityForConfigChanges() {
        // The engine survives rotation. Keep the pending document request so
        // the reattached activity can deliver its result exactly once.
        activityBinding?.removeActivityResultListener(this)
        activityBinding = null
    }

    override fun onDetachedFromActivity() {
        cancelPending()
        onDetachedFromActivityForConfigChanges()
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        cancelPending()
        channel.setMethodCallHandler(null)
        ioExecutor.shutdownNow()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "storeFanqieCapture" || call.method == "storeFanqieCapturePart" ||
            call.method == "latestFanqieCapture" || call.method == "readFanqieCapturePart") {
            captureFile(call, result)
            return
        }
        if (call.method != "openBackup" && call.method != "saveBackup" &&
            call.method != "exportFanqieCapture") {
            result.notImplemented()
            return
        }
        if (pending != null) {
            result.error("BACKUP_BUSY", "备份文件正在处理", null)
            return
        }
        val activity = activityBinding?.activity
        if (activity == null) {
            result.error("BACKUP_NO_ACTIVITY", "应用窗口不可用", null)
            return
        }
        val exporting = call.method == "exportFanqieCapture"
        val saving = call.method == "saveBackup" || exporting
        val bytes = if (saving) call.argument<ByteArray>("bytes") else null
        if (saving && (bytes == null || bytes.isEmpty() || bytes.size > MAX_BYTES)) {
            result.error("BACKUP_SIZE", "备份为空或超过 16 MB", null)
            return
        }
        val parts = if (exporting) {
            val supplied = call.argument<Any>("parts") as? List<*>
            if (supplied == null || supplied.size > MAX_PARTS ||
                supplied.any { it !is String || !PART_NAME.matches(it) } ||
                supplied.distinct().size != supplied.size) {
                result.error("CAPTURE_PARTS", "采集分卷参数无效或不完整，请重新采集", null)
                return
            }
            supplied.filterIsInstance<String>()
        } else null
        val intent = Intent(if (saving) Intent.ACTION_CREATE_DOCUMENT else Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = if (exporting) "application/zip" else if (saving) "application/json" else "*/*"
            if (saving) {
                val name = call.argument<String>("name")
                    ?.takeIf { it.matches(if (exporting) ZIP_NAME else Regex("[a-zA-Z0-9_.-]{1,100}\\.json")) }
                    ?: if (exporting) "fqapp-fanqie-capture.zip" else "fqapp-backup.json"
                putExtra(Intent.EXTRA_TITLE, name)
                addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            } else {
                // Some providers report JSON as plain text or octet-stream.
                putExtra(Intent.EXTRA_MIME_TYPES, arrayOf(
                    "application/json", "text/json", "text/plain", "application/octet-stream",
                ))
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
        }
        val request = Pending(result, nextRequest.getAndUpdate { if (it >= 62000) 54000 else it + 1 }, bytes, parts)
        pending = request
        try {
            activity.startActivityForResult(intent, request.requestCode)
        } catch (_: Exception) {
            pending = null
            result.error("BACKUP_PICKER_UNAVAILABLE", "无法打开系统文件选择器", null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        val request = pending ?: return false
        if (requestCode != request.requestCode) return false
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            pending = null
            request.result.success(if (request.bytes == null) null else false)
            return true
        }
        ioExecutor.execute {
            val completed = runCatching {
                require(uri.scheme == "content") { "不支持的文件来源" }
                if (request.bytes == null) readDocument(uri) else {
                    appContext.contentResolver.openOutputStream(uri, "wt")?.use { output ->
                        if (request.parts != null) {
                            ZipOutputStream(output).use { zip ->
                                check(pending === request && !Thread.currentThread().isInterrupted)
                                zip.putNextEntry(ZipEntry("manifest.json"))
                                zip.write(request.bytes)
                                zip.closeEntry()
                                val directory = captureDirectory()
                                val buffer = ByteArray(16 * 1024)
                                for (name in request.parts) {
                                    check(pending === request && !Thread.currentThread().isInterrupted)
                                    val part = capturePart(directory, name)
                                    zip.putNextEntry(ZipEntry(name))
                                    part.inputStream().use { input ->
                                        var total = 0
                                        while (true) {
                                            check(pending === request && !Thread.currentThread().isInterrupted)
                                            val count = input.read(buffer)
                                            if (count < 0) break
                                            total += count
                                            check(total <= MAX_BYTES)
                                            zip.write(buffer, 0, count)
                                        }
                                        check(total > 0)
                                    }
                                    zip.closeEntry()
                                }
                            }
                        } else {
                            output.write(request.bytes)
                            output.flush()
                        }
                    } ?: error("无法写入所选文件")
                    true
                }
            }
            mainHandler.post {
                if (pending !== request) return@post
                pending = null
                completed.fold(
                    onSuccess = { request.result.success(it) },
                    onFailure = {
                        request.result.error(
                            "BACKUP_IO_FAILED",
                            if (request.bytes == null) "读取失败，请选择不超过 16 MB 的备份文件"
                            else if (request.parts != null) "采集导出未能完整写入，请重新导出并选择新文件"
                            else "备份未能完整写入，请重新导出并使用新文件",
                            null,
                        )
                    },
                )
            }
        }
        return true
    }

    private fun readDocument(uri: Uri): ByteArray =
        appContext.contentResolver.openInputStream(uri)?.use { input ->
            val output = ByteArrayOutputStream()
            val buffer = ByteArray(16 * 1024)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                require(output.size() + count <= MAX_BYTES) { "备份文件超过 16 MB" }
                output.write(buffer, 0, count)
            }
            output.toByteArray()
        } ?: error("无法读取所选文件")

    private fun captureFile(call: MethodCall, result: MethodChannel.Result) {
        val storing = call.method == "storeFanqieCapture" || call.method == "storeFanqieCapturePart"
        val storingPart = call.method == "storeFanqieCapturePart"
        val bytes = if (storing) call.argument<ByteArray>("bytes") else null
        if (storing &&
            (bytes == null || bytes.isEmpty() || bytes.size > MAX_BYTES)) {
            result.error("CAPTURE_SIZE", "采集文件为空或超过 16 MB", null)
            return
        }
        ioExecutor.execute {
            val completed = runCatching {
                val directory = captureDirectory()
                if (call.method == "readFanqieCapturePart") {
                    val name = call.argument<String>("name") ?: error("缺少分卷名称")
                    check(name.matches(Regex("part-[0-9]+-[a-fA-F0-9-]+\\.json")))
                    val file = File(directory, name).canonicalFile
                    check(file.parentFile == directory.canonicalFile && file.isFile)
                    check(file.length() in 1..MAX_BYTES.toLong())
                    return@runCatching file.readBytes().also { check(it.size <= MAX_BYTES) }
                }
                if (bytes != null) {
                    check(directory.isDirectory || directory.mkdirs())
                    val prefix = if (storingPart) "part" else "capture"
                    val name = "$prefix-${System.currentTimeMillis()}-${UUID.randomUUID()}.json"
                    val destination = File(directory, name)
                    val temporary = File.createTempFile("pending-", ".tmp", directory)
                    try {
                        temporary.outputStream().use { output ->
                            output.write(bytes)
                            output.fd.sync()
                        }
                        check(!destination.exists() && temporary.renameTo(destination))
                    } finally {
                        if (temporary.exists()) temporary.delete()
                    }
                    if (storingPart) name else true
                } else {
                    val latest = directory.listFiles()
                        ?.filter { it.isFile && it.name.matches(Regex("capture-[0-9]+-[a-fA-F0-9-]+\\.json")) }
                        ?.maxByOrNull { it.name }
                    latest?.let {
                        check(it.length() in 1..MAX_BYTES.toLong())
                        it.inputStream().use { input ->
                            val output = ByteArrayOutputStream()
                            val buffer = ByteArray(16 * 1024)
                            while (true) {
                                val count = input.read(buffer)
                                if (count < 0) break
                                check(output.size() + count <= MAX_BYTES)
                                output.write(buffer, 0, count)
                            }
                            output.toByteArray()
                        }
                    }
                }
            }
            mainHandler.post {
                completed.fold(
                    onSuccess = { result.success(it) },
                    onFailure = { result.error("CAPTURE_IO_FAILED", "本机采集文件读写失败，可尝试导出", null) },
                )
            }
        }
    }

    private fun captureDirectory(): File {
        val directory = File(appContext.filesDir.canonicalFile, "fanqie-library-captures")
        check(directory.canonicalFile == directory.absoluteFile)
        return directory
    }

    private fun capturePart(directory: File, name: String): File {
        check(PART_NAME.matches(name))
        val part = File(directory, name)
        check(part.canonicalFile == part.absoluteFile)
        check(part.canonicalFile.parentFile == directory.canonicalFile)
        check(part.isFile && part.length() in 1..MAX_BYTES.toLong())
        return part
    }

    private fun cancelPending() {
        val request = pending ?: return
        pending = null
        request.result.error("BACKUP_INTERRUPTED", "文件操作已中断，请重新操作", null)
    }

    companion object {
        private const val MAX_BYTES = 16 * 1024 * 1024
        private const val MAX_PARTS = 2000
        private val PART_NAME = Regex("part-[0-9]+-[a-fA-F0-9-]+\\.json")
        private val ZIP_NAME = Regex("[a-zA-Z0-9_.-]{1,100}\\.zip")
        // Distinguish late results from a canceled picker and a new request.
        private val nextRequest = AtomicInteger(54000)
    }
}
