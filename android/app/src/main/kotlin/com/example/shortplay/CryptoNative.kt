// NB: package must stay com.example.shortplay — libshortplay_crypto.so exports
// JNI symbols bound to that package name (Java_com_example_shortplay_...).
package com.example.shortplay

import android.util.Log
import androidx.annotation.Keep
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
    private val client: okhttp3.OkHttpClient = okhttp3.OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .retryOnConnectionFailure(true)
        // Bypass the system/WiFi HTTP proxy and hit the CDN directly. OkHttp
        // defaults to ProxySelector.getDefault(), which picks up a per-network
        // proxy and breaks playback when that proxy is unreachable.
        .proxy(Proxy.NO_PROXY)
        .build()

    /**
     * Blocking GET of [url] with an inclusive Range header bytes=[start]-[end].
     */
    @JvmStatic
    fun httpRange(url: String, start: Long, end: Long): ByteArray? {
        return try {
            val req = okhttp3.Request.Builder()
                .url(url)
                .header("Range", "bytes=$start-$end")
                .build()
            client.newCall(req).execute().use { resp ->
                if (!resp.isSuccessful) {
                    Log.e("sp_crypto", "httpRange HTTP ${resp.code} for $url [$start-$end]")
                    return null
                }
                resp.body?.bytes()
            }
        } catch (t: Throwable) {
            Log.e("sp_crypto", "httpRange threw for $url [$start-$end]: ${t.javaClass.simpleName}: ${t.message}")
            null
        }
    }

    // ── Streaming GET (used for the mdat region) ────────────────────────────
    // An open-ended `Range: bytes=start-` request whose body is read chunk by
    // chunk, so the native producer can hand each arriving TCP segment to the
    // player immediately.
    private class Stream(val resp: okhttp3.Response, val input: InputStream)

    private val streams = ConcurrentHashMap<Long, Stream>()
    private val nextId = AtomicLong(1L)
    // Separate client: no read timeout, since a streamed body stays open and
    // may idle between chunks while the window is full (TCP backpressure).
    private val streamClient: okhttp3.OkHttpClient = client.newBuilder()
        .readTimeout(0, TimeUnit.SECONDS)
        .build()

    /** Open a streamed GET at [start]. Returns a stream id, or 0 on failure. */
    @JvmStatic
    fun streamOpen(url: String, start: Long): Long {
        return try {
            val req = okhttp3.Request.Builder()
                .url(url)
                .header("Range", "bytes=$start-")
                .build()
            val resp = streamClient.newCall(req).execute()
            val body = resp.body
            if (!resp.isSuccessful || body == null) {
                Log.e("sp_crypto", "streamOpen HTTP ${resp.code} for $url @$start")
                resp.close()
                return 0L
            }
            val id = nextId.getAndIncrement()
            streams[id] = Stream(resp, body.byteStream())
            id
        } catch (t: Throwable) {
            Log.e("sp_crypto", "streamOpen threw @$start: ${t.javaClass.simpleName}: ${t.message}")
            0L
        }
    }

    /**
     * Read the next chunk into [buf]. Returns bytes read (>0), 0 on clean EOF,
     * or -1 on error.
     */
    @JvmStatic
    fun streamRead(id: Long, buf: ByteArray): Int {
        val s = streams[id] ?: return -1
        return try {
            s.input.read(buf)  // -1 at EOF, mapped below to 0 for the C core
                .let { if (it < 0) 0 else it }
        } catch (t: Throwable) {
            Log.e("sp_crypto", "streamRead threw id=$id: ${t.javaClass.simpleName}: ${t.message}")
            -1
        }
    }

    /** Close and release a stream opened by [streamOpen]. */
    @JvmStatic
    fun streamClose(id: Long) {
        val s = streams.remove(id) ?: return
        try {
            s.resp.close()  // also closes the body / underlying stream
        } catch (_: Throwable) {
        }
    }
}
