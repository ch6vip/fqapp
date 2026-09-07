// NB: package must stay com.example.shortplay — libshortplay_crypto.so exports
// JNI symbols bound to that package name (Java_com_example_shortplay_...).
package com.example.shortplay

import android.util.Log
import androidx.annotation.Keep
import java.io.EOFException
import java.io.InputStream
import java.net.Proxy
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong

/**
 * Bridge to the shortplay C crypto core (libshortplay_crypto.so).
 *
 * The C core decrypts CENC-encrypted MP4 on the fly; all network I/O funnels
 * back through [HttpBridge.httpRange] / [HttpBridge.streamOpen]. ExoPlayer
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
        initialized = nativeInit(HttpBridge::class.java)
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
 * Returns the response body bytes, or null on any error (the C core treats
 * null/short reads as a fetch failure and aborts the stream cleanly).
 */
@Keep
object HttpBridge {
    private val bridge = HttpRangeClient(okhttp3.OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .callTimeout(45, TimeUnit.SECONDS)
        .retryOnConnectionFailure(true)
        // Bypass the system/WiFi HTTP proxy and hit the CDN directly. OkHttp
        // defaults to ProxySelector.getDefault(), which picks up a per-network
        // proxy and breaks playback when that proxy is unreachable.
        .proxy(Proxy.NO_PROXY)
        .build())

    @JvmStatic
    fun httpRange(url: String, start: Long, end: Long): ByteArray? =
        bridge.httpRange(url, start, end)

    @JvmStatic
    fun streamOpen(url: String, start: Long): Long = bridge.streamOpen(url, start)

    @JvmStatic
    fun streamRead(id: Long, buf: ByteArray): Int = bridge.streamRead(id, buf)

    @JvmStatic
    fun streamClose(id: Long) = bridge.streamClose(id)
}

/** Network implementation kept independent of JNI so its HTTP contract can be tested. */
internal class HttpRangeClient(
    private val client: okhttp3.OkHttpClient,
    private val logError: (String) -> Unit = { Log.e("sp_crypto", it) },
) {
    private data class ResponseRange(val length: Long)
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
            return if (start == 0L) ResponseRange(body.contentLength()) else null
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
        return ResponseRange(length)
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
            logError("httpRange threw for [$start-$end]: ${t.javaClass.simpleName}: ${t.message}")
            null
        }
    }

    // ── Streaming GET (used for the mdat region) ────────────────────────────
    // An open-ended `Range: bytes=start-` request whose body is read chunk by
    // chunk, so the native producer can hand each arriving TCP segment to the
    // player immediately.
    private class Stream(
        val call: okhttp3.Call,
        val resp: okhttp3.Response,
        val input: InputStream,
        var remaining: Long,
    )

    private val streams = ConcurrentHashMap<Long, Stream>()
    private val nextId = AtomicLong(1L)

    /** Open a streamed GET at [start]. Returns a stream id, or 0 on failure. */
    fun streamOpen(url: String, start: Long): Long {
        if (start < 0) return 0L
        return try {
            val req = okhttp3.Request.Builder()
                .url(url)
                .header("Range", "bytes=$start-")
                .header("Accept-Encoding", "identity")
                .build()
            val call = streamClient.newCall(req)
            val resp = call.execute()
            var retained = false
            try {
                val range = responseRange(resp, start, null)
                if (range == null) {
                    logError("streamOpen invalid HTTP ${resp.code} response @$start")
                    return 0L
                }
                val id = nextId.getAndIncrement()
                streams[id] = Stream(call, resp, resp.body!!.byteStream(), range.length)
                retained = true
                id
            } finally {
                if (!retained) resp.close()
            }
        } catch (t: Throwable) {
            logError("streamOpen threw @$start: ${t.javaClass.simpleName}: ${t.message}")
            0L
        }
    }

    /**
     * Read the next chunk into [buf]. Returns bytes read (>0), 0 on clean EOF,
     * or -1 on error.
     */
    fun streamRead(id: Long, buf: ByteArray): Int {
        val s = streams[id] ?: return -1
        return try {
            if (buf.isEmpty() || s.remaining == 0L) return 0
            val length = if (s.remaining < 0) buf.size else minOf(buf.size.toLong(), s.remaining).toInt()
            val read = s.input.read(buf, 0, length)
            if (read < 0) {
                if (s.remaining > 0) throw EOFException("HTTP stream ended before its declared range")
                0
            } else {
                if (s.remaining >= 0) s.remaining -= read
                read
            }
        } catch (t: Throwable) {
            streamClose(id)
            logError("streamRead threw id=$id: ${t.javaClass.simpleName}: ${t.message}")
            -1
        }
    }

    /** Close and release a stream opened by [streamOpen]. */
    fun streamClose(id: Long) {
        val s = streams.remove(id) ?: return
        s.call.cancel() // Interrupt an in-flight read before closing its body.
        try {
            s.resp.close()  // also closes the body / underlying stream
        } catch (_: Throwable) {
        }
    }
}
