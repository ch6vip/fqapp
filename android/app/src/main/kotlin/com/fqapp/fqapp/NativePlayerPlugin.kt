package com.fqapp.fqapp

import android.app.Activity
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.view.WindowManager
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.BaseDataSource
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.HttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import com.example.shortplay.CryptoNative
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/**
 * Native ExoPlayer host for DRM (CENC) short dramas. Decrypted plaintext is
 * served to ExoPlayer through a [CryptoDataSource] backed by the C crypto
 * core; events (position/playing/firstFrame/...) are pushed to Flutter over
 * an EventChannel.
 */
@androidx.annotation.OptIn(UnstableApi::class)
class NativePlayerPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware {

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private lateinit var textureRegistry: TextureRegistry
    private lateinit var flutterBinding: FlutterPlugin.FlutterPluginBinding
    @Volatile private var attachedToEngine = false

    private var activity: Activity? = null
    private val players = ConcurrentHashMap<Int, PlayerInstance>()
    private val cancelledPlayerIds = ConcurrentHashMap.newKeySet<Int>()
    private val nextId = AtomicInteger(1)
    private val handler = Handler(Looper.getMainLooper())
    private val backgroundExecutor = Executors.newCachedThreadPool()

    private var eventSink: EventChannel.EventSink? = null

    private data class PlayerInstance(
        val id: Int,
        val player: ExoPlayer,
        val videoOutput: NativeVideoOutput,
        var positionUpdater: Runnable? = null
    )

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        attachedToEngine = true
        flutterBinding = binding
        textureRegistry = binding.textureRegistry
        methodChannel = MethodChannel(binding.binaryMessenger, "fqapp/native_player")
        methodChannel.setMethodCallHandler(this)
        eventChannel = EventChannel(binding.binaryMessenger, "fqapp/native_player/events")
        eventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                eventSink = events
            }
            override fun onCancel(arguments: Any?) {
                eventSink = null
            }
        })
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }
    override fun onDetachedFromActivityForConfigChanges() { activity = null }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }
    override fun onDetachedFromActivity() { activity = null }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        attachedToEngine = false
        activity = null
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        players.keys.toList().forEach { disposePlayer(it) }
        handler.removeCallbacksAndMessages(null)
        cancelledPlayerIds.clear()
        eventSink = null
        backgroundExecutor.shutdownNow()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "create" -> {
                val cdnUrl = call.argument<String>("cdnUrl")!!
                val keyHex = call.argument<String>("keyHex")!!
                handleCreate(cdnUrl, keyHex, result)
            }
            "play" -> {
                val id = call.argument<Int>("id")!!
                players[id]?.player?.play()
                result.success(null)
            }
            "pause" -> {
                val id = call.argument<Int>("id")!!
                players[id]?.player?.pause()
                result.success(null)
            }
            "seek" -> {
                val id = call.argument<Int>("id")!!
                val positionMs = call.argument<Number>("positionMs")!!.toLong()
                players[id]?.player?.seekTo(positionMs)
                result.success(null)
            }
            "setVolume" -> {
                val id = call.argument<Int>("id")!!
                val volume = call.argument<Number>("volume")!!.toFloat()
                players[id]?.player?.volume = volume
                result.success(null)
            }
            "setRate" -> {
                val id = call.argument<Int>("id")!!
                val rate = call.argument<Number>("rate")!!.toFloat()
                players[id]?.player?.playbackParameters = PlaybackParameters(rate)
                result.success(null)
            }
            "dispose" -> {
                val id = call.argument<Int>("id")!!
                disposePlayer(id)
                result.success(null)
            }
            "setKeepScreenOn" -> {
                val on = call.argument<Boolean>("on") ?: false
                handler.post {
                    activity?.window?.let { w ->
                        if (on) w.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        else w.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun handleCreate(cdnUrl: String, keyHex: String, result: MethodChannel.Result) {
        val playerId = nextId.getAndIncrement()
        result.success(mapOf("playerId" to playerId, "textureId" to -1))

        if (keyHex.isEmpty()) {
            handler.post {
                if (attachedToEngine && !cancelledPlayerIds.remove(playerId)) {
                    createPlayerWithUri(playerId, cdnUrl)
                }
            }
        } else {
            try {
                CryptoNative.ensureInit()
                backgroundExecutor.execute {
                    try {
                        if (cancelledPlayerIds.remove(playerId)) return@execute
                        // Probe-only open: verifies the CDN + key are playable.
                        val probeHandle = CryptoNative.nativePlayerStreamOpen(cdnUrl, keyHex)
                        if (probeHandle == 0L) {
                            sendEvent(playerId, "error", "sp_stream_open failed")
                            return@execute
                        }
                        CryptoNative.nativePlayerStreamClose(probeHandle)
                        handler.post {
                            if (attachedToEngine && !cancelledPlayerIds.remove(playerId)) {
                                createPlayerWithCrypto(playerId, cdnUrl, keyHex)
                            }
                        }
                    } catch (error: Throwable) {
                        sendEvent(playerId, "error", error.message ?: error.javaClass.simpleName)
                    }
                }
            } catch (error: Throwable) {
                sendEvent(playerId, "error", error.message ?: error.javaClass.simpleName)
            }
        }
    }

    private fun createPlayerWithUri(playerId: Int, uri: String) {
        createPlayer(playerId) { player ->
            player.setMediaItem(MediaItem.fromUri(uri))
        }
    }

    private fun createPlayerWithCrypto(playerId: Int, cdnUrl: String, keyHex: String) {
        createPlayer(playerId) { player ->
            val dataSourceFactory = DataSource.Factory {
                CryptoDataSource(cdnUrl, keyHex)
            }
            val mediaSource = ProgressiveMediaSource.Factory(dataSourceFactory)
                .createMediaSource(MediaItem.fromUri("crypto://$cdnUrl"))
            player.setMediaSource(mediaSource)
        }
    }

    private fun createPlayer(playerId: Int, configure: (ExoPlayer) -> Unit) {
        if (!attachedToEngine) return
        if (cancelledPlayerIds.remove(playerId)) return
        var producer: TextureRegistry.SurfaceProducer? = null
        var player: ExoPlayer? = null
        var output: NativeVideoOutput? = null
        try {
            // SurfaceProducer uses decoder buffers directly on Vulkan. The
            // legacy SurfaceTexture path copies through GL and reallocates a
            // buffer at each animated display size, causing black video frames.
            // MediaCodec supplies the buffer dimensions; don't resize the
            // producer to match the description panel's Flutter rectangle.
            producer = textureRegistry.createSurfaceProducer()
            player = ExoPlayer.Builder(flutterBinding.applicationContext).build()
            output = NativeVideoOutput(player, producer)
            players[playerId] = PlayerInstance(playerId, player, output)
            output.attach()
            setupPlayerListener(playerId, player)
            configure(player)
            player.prepare()
            sendEvent(playerId, "created", output.textureId)
        } catch (error: Throwable) {
            players.remove(playerId)
            if (output != null) {
                output.release()
            } else {
                try {
                    player?.release()
                } finally {
                    producer?.release()
                }
            }
            sendEvent(playerId, "error", error.message ?: error.javaClass.simpleName)
        }
    }

    private fun setupPlayerListener(playerId: Int, player: ExoPlayer) {
        var firstFrameSent = false

        player.addListener(object : Player.Listener {
            override fun onPlaybackStateChanged(playbackState: Int) {
                when (playbackState) {
                    Player.STATE_BUFFERING -> sendEvent(playerId, "buffering", true)
                    Player.STATE_READY -> {
                        sendEvent(playerId, "buffering", false)
                        sendEvent(playerId, "duration", player.duration)
                    }
                    Player.STATE_ENDED -> {
                        // The periodic updater stops with isPlaying. Publish
                        // the exact end position before saving stop-at-end history.
                        sendEvent(playerId, "position", player.currentPosition)
                        sendEvent(playerId, "completed", true)
                    }
                    Player.STATE_IDLE -> {}
                }
            }

            override fun onIsPlayingChanged(isPlaying: Boolean) {
                sendEvent(playerId, "playing", isPlaying)
                if (isPlaying) {
                    startPositionUpdates(playerId)
                }
            }

            override fun onVideoSizeChanged(videoSize: VideoSize) {
                if (videoSize.width > 0 && videoSize.height > 0) {
                    val instance = players[playerId] ?: return
                    // Media3 reports display width/height after rotation. Its
                    // ImageReader output still needs the format rotation in
                    // Flutter; SurfaceTexture producers already apply it.
                    val rotation = instance.videoOutput.rotationCorrection(
                        player.videoFormat?.rotationDegrees ?: 0
                    )
                    handler.post {
                        if (!attachedToEngine || players[playerId] !== instance) return@post
                        eventSink?.success(mapOf(
                            "playerId" to playerId,
                            "type" to "videoSize",
                            "width" to videoSize.width,
                            "height" to videoSize.height,
                            "rotationCorrection" to rotation
                        ))
                    }
                }
            }

            override fun onRenderedFirstFrame() {
                if (!firstFrameSent) {
                    firstFrameSent = true
                    sendEvent(playerId, "firstFrame", true)
                }
            }

            override fun onPlayerError(error: PlaybackException) {
                // "Source error" alone loses the difference between a network
                // timeout, an expired URL and a server response. Keep the
                // stable codes for Flutter's user-facing explanation.
                val httpError = generateSequence(error as Throwable) { it.cause }
                    .take(8)
                    .filterIsInstance<HttpDataSource.InvalidResponseCodeException>()
                    .firstOrNull()
                sendEvent(
                    playerId,
                    "error",
                    mapOf(
                        "message" to (error.message ?: "ExoPlayer error"),
                        "errorCode" to error.errorCode,
                        "httpStatusCode" to httpError?.responseCode
                    )
                )
            }
        })
    }

    private fun startPositionUpdates(playerId: Int) {
        val instance = players[playerId] ?: return
        instance.positionUpdater?.let(handler::removeCallbacks)
        val updater = object : Runnable {
            override fun run() {
                val current = players[playerId] ?: return
                val player = current.player
                if (player.isPlaying) {
                    sendEvent(playerId, "position", player.currentPosition)
                    handler.postDelayed(this, 200)
                } else {
                    current.positionUpdater = null
                }
            }
        }
        instance.positionUpdater = updater
        handler.post(updater)
    }

    private fun sendEvent(playerId: Int, type: String, value: Any) {
        handler.post {
            if (attachedToEngine) {
                eventSink?.success(mapOf("playerId" to playerId, "type" to type, "value" to value))
            }
        }
    }

    private fun disposePlayer(id: Int) {
        val instance = players.remove(id)
        if (instance == null) {
            // Creation/probing can still be in flight. The creation path
            // consumes this marker before allocating a texture or player.
            cancelledPlayerIds.add(id)
            handler.postDelayed({ cancelledPlayerIds.remove(id) }, 30_000)
            return
        }
        instance.positionUpdater?.let(handler::removeCallbacks)
        instance.videoOutput.release()
    }

    private inner class CryptoDataSource(
        private val cdnUrl: String,
        private val keyHex: String
    ) : BaseDataSource(true) {

        private var streamHandle: Long = 0L
        private var uri: Uri? = null
        private var bytesRemaining: Long = C.LENGTH_UNSET.toLong()
        private var opened = false
        // Reused across read() calls so the hot path doesn't allocate a fresh
        // buffer for every chunk.
        private var readBuffer: ByteArray? = null

        override fun open(dataSpec: DataSpec): Long {
            uri = dataSpec.uri
            streamHandle = CryptoNative.nativePlayerStreamOpen(cdnUrl, keyHex)
            if (streamHandle == 0L) {
                throw java.io.IOException("Failed to open crypto stream")
            }
            val totalSize = CryptoNative.nativePlayerStreamSize(streamHandle)
            if (dataSpec.position > 0) {
                CryptoNative.nativePlayerStreamSeek(streamHandle, dataSpec.position)
            }
            bytesRemaining = if (dataSpec.length != C.LENGTH_UNSET.toLong()) {
                dataSpec.length
            } else if (totalSize > 0) {
                totalSize - dataSpec.position
            } else {
                C.LENGTH_UNSET.toLong()
            }
            transferStarted(dataSpec)
            opened = true
            return bytesRemaining
        }

        override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
            if (length == 0) return 0
            if (bytesRemaining == 0L) return C.RESULT_END_OF_INPUT
            val toRead = if (bytesRemaining != C.LENGTH_UNSET.toLong()) {
                minOf(length.toLong(), bytesRemaining).toInt()
            } else {
                length
            }
            var tmp = readBuffer
            if (tmp == null || tmp.size < toRead) {
                tmp = ByteArray(toRead)
                readBuffer = tmp
            }
            val bytesRead = CryptoNative.nativePlayerStreamRead(streamHandle, tmp, toRead)
            if (bytesRead <= 0) return C.RESULT_END_OF_INPUT
            System.arraycopy(tmp, 0, buffer, offset, bytesRead)
            if (bytesRemaining != C.LENGTH_UNSET.toLong()) {
                bytesRemaining -= bytesRead
            }
            bytesTransferred(bytesRead)
            return bytesRead
        }

        override fun getUri(): Uri? = uri

        override fun close() {
            if (streamHandle != 0L) {
                CryptoNative.nativePlayerStreamClose(streamHandle)
                streamHandle = 0L
            }
            if (opened) {
                opened = false
                transferEnded()
            }
        }
    }
}
