// NB: package must stay com.example.shortplay — libshortplay_crypto.so exports
// JNI symbols bound to that package name (Java_com_example_shortplay_...).
package com.example.shortplay

import android.util.Log
import androidx.annotation.Keep
import java.io.EOFException
import java.io.IOException
import java.io.InputStream
import java.net.Proxy
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong

/**
 * Bridge to the shortplay C crypto core (libshortplay_crypto.so).
 *
 * The C core decrypts CENC-encrypted MP4 on the fly; all network I/O funnels
 * back through [HttpBridge.httpSize] / [HttpBridge.streamPrepare]. ExoPlayer
 * reads decrypted plaintext through the nativePlayerStream* ABI.
 */
@Keep
object CryptoNative {
    @Volatile private var initialized = false

    init {
        System.loadLibrary("shortplay_crypto")
    }

    /** Cache the HttpBridge class on the native side. Idempotent. */
    @Synchronized
    fun ensureInit() {
        if (initialized) return
        if (!nativeInit(HttpBridge::class.java)) {
            throw IOException("Failed to initialize the native crypto bridge")
        }
        initialized = true
    }

    fun prewarm(cdnUrl: String, keyHex: String): Int {
        ensureInit()
        return nativePrewarm(cdnUrl, keyHex)
    }

    fun prewarmHeaderOnly(cdnUrl: String, keyHex: String): Int {
        ensureInit()
        return nativePrewarmHeaderOnly(cdnUrl, keyHex)
    }

    private external fun nativeInit(bridge: Class<*>): Boolean
    private external fun nativePrewarm(cdnUrl: String, keyHex: String): Int
    private external fun nativePrewarmHeaderOnly(cdnUrl: String, keyHex: String): Int

    // ExoPlayer DataSource stream methods
    @JvmStatic external fun nativePlayerStreamOpen(url: String, keyHex: String): Long
    @JvmStatic external fun nativePlayerStreamRead(handle: Long, buf: ByteArray, len: Int): Int
    @JvmStatic external fun nativePlayerStreamSeek(handle: Long, offset: Long): Long
    @JvmStatic external fun nativePlayerStreamSize(handle: Long): Long
    @JvmStatic external fun nativePlayerStreamClose(handle: Long)
}

/**
 * OkHttp-backed HTTP range fetcher invoked from native code. Kept as a
 * top-level object with a single static-style entry point so the JNI layer
 * can resolve it via GetStaticMethodID without holding an instance.
 *
 * The size probe requires byte ranges. Stream reads return a bounded positive
 * count, zero at EOF, or -1 on failure; native code turns failures into IOException.
 */
@Keep
object HttpBridge {
    // One id space for both bridges: the native side treats stream ids as
    // opaque jlongs, but they must never collide across the two maps.
    private val streamIds = AtomicLong(1L)
    private val playbackHttpStatus = ConcurrentHashMap<String, Int>()

    private val bridge = HttpRangeClient(okhttp3.OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .callTimeout(45, TimeUnit.SECONDS)
        .retryOnConnectionFailure(true)
        // Bypass the system/WiFi HTTP proxy and hit the CDN directly. OkHttp
        // defaults to ProxySelector.getDefault(), which picks up a per-network
        // proxy and breaks playback when that proxy is unreachable.
        .proxy(Proxy.NO_PROXY)
        .build(),
        nextId = streamIds,
        onHttpStatus = { url, status -> playbackHttpStatus[url] = status })

    private val fileBridge = OfflineFileBridge(streamIds)

    /** Ephemeral diagnostic metadata only; callers clear it when the player is released. */
    fun lastHttpStatus(url: String): Int? = playbackHttpStatus[url]

    fun clearHttpStatus(url: String) {
        playbackHttpStatus.remove(url)
    }

    @JvmStatic
    fun httpRange(url: String, start: Long, end: Long): ByteArray? =
        if (url.startsWith("file://")) fileBridge.httpRange(url, start, end)
        else bridge.httpRange(url, start, end)

    @JvmStatic
    fun httpSize(url: String): Long =
        if (url.startsWith("file://")) fileBridge.httpSize(url)
        else bridge.httpSize(url)

    @JvmStatic
    fun streamPrepare(url: String, start: Long, expectedSize: Long): Long =
        if (url.startsWith("file://")) fileBridge.streamPrepare(url, start, expectedSize)
        else bridge.streamPrepare(url, start, expectedSize)

    @JvmStatic
    fun streamConnect(id: Long): Boolean =
        if (fileBridge.owns(id)) fileBridge.streamConnect(id) else bridge.streamConnect(id)

    @JvmStatic
    fun streamOpen(url: String, start: Long): Long =
        if (url.startsWith("file://")) fileBridge.streamOpen(url, start)
        else bridge.streamOpen(url, start)

    @JvmStatic
    fun streamRead(id: Long, buf: ByteArray): Int = streamRead(id, buf, buf.size)

    @JvmStatic
    fun streamRead(id: Long, buf: ByteArray, length: Int): Int =
        if (fileBridge.owns(id)) fileBridge.streamRead(id, buf, length)
        else bridge.streamRead(id, buf, length)

    @JvmStatic
    fun streamClose(id: Long) {
        if (fileBridge.owns(id)) fileBridge.streamClose(id) else bridge.streamClose(id)
    }
}

/**
 * Local-file twin of the HTTP range bridge, used for offline-cached episodes:
 * the download store keeps the original CENC-encrypted MP4 bytes plus the
 * per-episode key, and playback passes a file:// URL so the native crypto
 * core reads (and decrypts) from disk through the same sp_io contract. The
 * native layer treats URLs as opaque strings, so no JNI/C changes are needed.
 *
 * Mirrors HttpRangeClient's contract exactly: size > 0 or -1, stream ids > 0
 * (0 on prepare failure), read returns >0, 0 at EOF, -1 on error, and a
 * prepared stream must hit exactly [expectedSize] total or connect fails —
 * which is what surfaces a truncated/corrupted download to the player.
 */
@Keep
private class OfflineFileBridge(streamIds: AtomicLong) {
    private val nextId = streamIds

    private class OfflineStream(val file: java.io.File, val start: Long, var remaining: Long) {
        var raf: java.io.RandomAccessFile? = null
        var closed = false
        var connected = false
    }

    private val streams = java.util.concurrent.ConcurrentHashMap<Long, OfflineStream>()

    private fun fileOf(url: String): java.io.File? {
        val path = runCatching { android.net.Uri.parse(url).path }.getOrNull()
        if (path.isNullOrEmpty()) return null
        val file = java.io.File(path)
        return if (file.isFile) file else null
    }

    fun owns(id: Long): Boolean = streams.containsKey(id)

    fun httpSize(url: String): Long {
        val file = fileOf(url) ?: return -1L
        val length = file.length()
        return if (length > 0L) length else -1L
    }

    fun httpRange(url: String, start: Long, end: Long): ByteArray? {
        if (start < 0 || end < start || end - start >= Int.MAX_VALUE) return null
        val file = fileOf(url) ?: return null
        val length = (end - start + 1).toInt()
        return try {
            java.io.RandomAccessFile(file, "r").use { raf ->
                if (file.length() < end + 1) return null
                raf.seek(start)
                val buf = ByteArray(length)
                var read = 0
                while (read < length) {
                    val n = raf.read(buf, read, length - read)
                    if (n < 0) break
                    read += n
                }
                if (read != length) null else buf
            }
        } catch (t: Throwable) {
            android.util.Log.e("sp_crypto", "file httpRange threw: ${t.javaClass.simpleName}")
            null
        }
    }

    fun streamPrepare(url: String, start: Long, expectedSize: Long): Long {
        if (start < 0 || expectedSize < -1 || (expectedSize >= 0 && start >= expectedSize)) return 0L
        val file = fileOf(url) ?: return 0L
        val total = file.length()
        if (total <= 0L || (expectedSize >= 0 && total != expectedSize)) return 0L
        if (start >= total) return 0L
        val id = nextId.getAndIncrement()
        if (id <= 0L) return 0L
        streams[id] = OfflineStream(file, start, total - start)
        return id
    }

    fun streamConnect(id: Long): Boolean {
        val s = streams[id] ?: return false
        synchronized(s) {
            if (s.closed || s.connected) return s.connected && !s.closed
            val raf = try {
                java.io.RandomAccessFile(s.file, "r").apply { seek(s.start) }
            } catch (t: Throwable) {
                android.util.Log.e("sp_crypto", "file streamConnect threw: ${t.javaClass.simpleName}")
                return false
            }
            s.raf = raf
            s.connected = true
            return true
        }
    }

    fun streamOpen(url: String, start: Long): Long {
        val id = streamPrepare(url, start, -1)
        return if (id != 0L && streamConnect(id)) id else 0L
    }

    fun streamRead(id: Long, buf: ByteArray, length: Int): Int {
        if (length < 0 || length > buf.size) return -1
        val s = streams[id] ?: return -1
        if (length == 0) return 0
        synchronized(s) {
            if (s.closed) return -1
            val raf = s.raf ?: return -1
            return try {
                if (s.remaining == 0L) return 0
                val toRead = minOf(length.toLong(), s.remaining).toInt()
                val read = raf.read(buf, 0, toRead)
                when {
                    read < 0 -> if (s.remaining > 0L) -1 else 0
                    read == 0 -> -1
                    else -> {
                        s.remaining -= read
                        read
                    }
                }
            } catch (t: Throwable) {
                streamClose(id)
                android.util.Log.e("sp_crypto", "file streamRead threw id=$id: ${t.javaClass.simpleName}")
                -1
            }
        }
    }

    fun streamClose(id: Long) {
        val s = streams.remove(id) ?: return
        synchronized(s) {
            s.closed = true
            try {
                s.raf?.close()
            } catch (_: Throwable) {
            }
            s.raf = null
        }
    }
}

/** Network implementation kept independent of JNI so its HTTP contract can be tested. */
internal class HttpRangeClient(
    private val client: okhttp3.OkHttpClient,
    private val logError: (String) -> Unit = { Log.e("sp_crypto", it) },
    // Shared with OfflineFileBridge so both maps never hand out the same id.
    private val nextId: AtomicLong = AtomicLong(1L),
    private val onHttpStatus: (String, Int) -> Unit = { _, _ -> },
) {
    private data class ResponseRange(val length: Long, val total: Long?)
    private val contentRange = Regex("bytes\\s+(\\d+)-(\\d+)/(\\d+|\\*)", RegexOption.IGNORE_CASE)

    // A read timeout runs only while an actual read is blocked. Pausing the
    // native consumer does not need an infinite read timeout, which would also
    // leave response headers and stalled downloads waiting forever. Streaming
    // has no whole-call deadline because playback can legitimately take hours.
    private val streamClient = client.newBuilder().callTimeout(0, TimeUnit.SECONDS).build()

    private fun responseRange(resp: okhttp3.Response, start: Long, end: Long?): ResponseRange? {
        val body = resp.body ?: return null
        val encoding = resp.header("Content-Encoding")
        if (encoding != null && !encoding.equals("identity", ignoreCase = true)) return null
        if (resp.code == 200) {
            // A server may ignore Range at the beginning of a file. A full
            // response at a nonzero offset would silently decrypt wrong bytes.
            return if (start == 0L) {
                val length = body.contentLength()
                ResponseRange(length, length.takeIf { it >= 0 })
            } else null
        }
        if (resp.code != 206) return null
        val match = contentRange.matchEntire(resp.header("Content-Range")?.trim() ?: "") ?: return null
        val first = match.groupValues[1].toLongOrNull() ?: return null
        val last = match.groupValues[2].toLongOrNull() ?: return null
        if (first != start || last < first || last - first == Long.MAX_VALUE) return null
        val totalText = match.groupValues[3]
        val total = if (totalText == "*") null else totalText.toLongOrNull() ?: return null
        if (total != null && total <= last) return null
        val expectedEnd = if (total == null) end else if (end == null) total - 1 else minOf(end, total - 1)
        if (expectedEnd != null && last != expectedEnd) return null
        val length = last - first + 1
        if (body.contentLength() >= 0 && body.contentLength() != length) return null
        return ResponseRange(length, total)
    }

    /** Prove byte-range support and get the total size without downloading the movie. */
    fun httpSize(url: String): Long {
        return try {
            val req = okhttp3.Request.Builder()
                .url(url)
                .header("Range", "bytes=0-0")
                .header("Accept-Encoding", "identity")
                .build()
            client.newCall(req).execute().use { resp ->
                onHttpStatus(url, resp.code)
                val range = responseRange(resp, 0, 0)
                val total = range?.total
                if (resp.code != 206 || range == null || range.length != 1L || total == null || total <= 0L) {
                    logError("httpSize requires a complete byte-range size in HTTP 206")
                    return -1L
                }
                // A Content-Range header alone is not proof of an actual byte.
                // readByte throws for truncated responses and use closes every path.
                resp.body!!.source().readByte()
                total
            }
        } catch (t: Throwable) {
            logError("httpSize threw: ${t.javaClass.simpleName}")
            -1L
        }
    }

    /**
     * Blocking GET of [url] with an inclusive Range header bytes=[start]-[end].
     */
    fun httpRange(url: String, start: Long, end: Long): ByteArray? {
        if (start < 0 || end < start || end - start >= Int.MAX_VALUE) return null
        val requestedLength = end - start + 1
        return try {
            val req = okhttp3.Request.Builder()
                .url(url)
                .header("Range", "bytes=$start-$end")
                .header("Accept-Encoding", "identity")
                .build()
            client.newCall(req).execute().use { resp ->
                onHttpStatus(url, resp.code)
                val range = responseRange(resp, start, end)
                if (range == null) {
                    logError("httpRange invalid HTTP ${resp.code} response for [$start-$end]")
                    return null
                }
                // Bound the allocation even when a server ignores Range and
                // returns the complete movie with HTTP 200.
                val length = if (range.length < 0) requestedLength else minOf(requestedLength, range.length)
                resp.body!!.source().readByteArray(length)
            }
        } catch (t: Throwable) {
            logError("httpRange threw for [$start-$end]: ${t.javaClass.simpleName}")
            null
        }
    }

    // ── Streaming GET (used for the mdat region) ────────────────────────────
    // An open-ended `Range: bytes=start-` request whose body is read chunk by
    // chunk, so the native producer can hand each arriving TCP segment to the
    // player immediately.
    private class Stream(
        val url: String,
        val call: okhttp3.Call,
        val start: Long,
        val expectedSize: Long,
    ) {
        // Close only takes the short state monitor. It never waits for the
        // readLock, so it can interrupt a thread blocked in read/execute.
        val readLock = Any()
        var connecting = false
        var closed = false
        var resp: okhttp3.Response? = null
        var input: InputStream? = null
        var remaining = -1L
    }

    private val streams = ConcurrentHashMap<Long, Stream>()

    /** Register the request before execute so native close can cancel response headers too. */
    fun streamPrepare(url: String, start: Long, expectedSize: Long): Long {
        if (start < 0 || expectedSize < -1 || (expectedSize >= 0 && start >= expectedSize)) return 0L
        return try {
            val req = okhttp3.Request.Builder()
                .url(url)
                .header("Range", "bytes=$start-")
                .header("Accept-Encoding", "identity")
                .build()
            val call = streamClient.newCall(req)
            val id = nextId.getAndIncrement()
            if (id <= 0L) return 0L
            streams[id] = Stream(url, call, start, expectedSize)
            id
        } catch (t: Throwable) {
            logError("streamPrepare threw @$start: ${t.javaClass.simpleName}")
            0L
        }
    }

    /** Complete a prepared request; a concurrent streamClose interrupts execute. */
    fun streamConnect(id: Long): Boolean {
        val s = streams[id] ?: return false
        synchronized(s) {
            if (s.closed) return false
            if (s.resp != null) return true
            if (s.connecting) return false
            s.connecting = true
        }
        var resp: okhttp3.Response? = null
        var retained = false
        return try {
            val response = s.call.execute()
            resp = response
            onHttpStatus(s.url, response.code)
            val range = responseRange(response, s.start, null)
            if (range == null || (s.expectedSize >= 0 && range.total != s.expectedSize)) {
                logError("streamConnect invalid HTTP ${response.code} response @${s.start}")
                return false
            }
            synchronized(s) {
                if (!s.closed) {
                    s.resp = response
                    s.input = response.body!!.byteStream()
                    s.remaining = range.length
                    retained = true
                }
            }
            retained
        } catch (t: Throwable) {
            logError("streamConnect threw @${s.start}: ${t.javaClass.simpleName}")
            false
        } finally {
            if (!retained) {
                streamClose(id)
                try {
                    resp?.close()
                } catch (_: Throwable) {
                }
            }
        }
    }

    /** Open a streamed GET at [start]. Returns a stream id, or 0 on failure. */
    fun streamOpen(url: String, start: Long): Long {
        val id = streamPrepare(url, start, -1)
        return if (id != 0L && streamConnect(id)) id else 0L
    }

    /**
     * Read the next chunk into [buf]. Returns bytes read (>0), 0 on clean EOF,
     * or -1 on error.
     */
    fun streamRead(id: Long, buf: ByteArray): Int = streamRead(id, buf, buf.size)

    fun streamRead(id: Long, buf: ByteArray, length: Int): Int {
        if (length < 0 || length > buf.size) return -1
        val s = streams[id] ?: return -1
        return synchronized(s.readLock) {
            try {
                val input: InputStream
                val available: Long
                synchronized(s) {
                    if (s.closed) return -1
                    input = s.input ?: return -1
                    available = s.remaining
                }
                if (length == 0 || available == 0L) return 0
                val toRead = if (available < 0) length else minOf(length.toLong(), available).toInt()
                val read = input.read(buf, 0, toRead)
                synchronized(s) {
                    if (s.closed) return -1
                    if (read < 0) {
                        if (s.remaining > 0) throw EOFException("HTTP stream ended before its declared range")
                        0
                    } else {
                        if (s.remaining >= 0) s.remaining -= read
                        read
                    }
                }
            } catch (t: Throwable) {
                streamClose(id)
                logError("streamRead threw id=$id: ${t.javaClass.simpleName}")
                -1
            }
        }
    }

    /** Close and release a stream opened by [streamOpen]. */
    fun streamClose(id: Long) {
        val s = streams.remove(id) ?: return
        val response = synchronized(s) {
            s.closed = true
            s.resp
        }
        s.call.cancel() // Interrupt an in-flight read before closing its body.
        try {
            response?.close()  // also closes the body / underlying stream
        } catch (_: Throwable) {
        }
    }
}
