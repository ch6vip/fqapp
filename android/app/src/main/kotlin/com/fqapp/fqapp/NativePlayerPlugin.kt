package com.fqapp.fqapp

import android.app.Activity
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.view.Surface
import android.view.WindowManager
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.datasource.BaseDataSource
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
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
class NativePlayerPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware {

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private lateinit var textureRegistry: TextureRegistry
    private lateinit var flutterBinding: FlutterPlugin.FlutterPluginBinding

    private var activity: Activity? = null
    private val players = ConcurrentHashMap<Int, PlayerInstance>()
    private val nextId = AtomicInteger(1)
    private val handler = Handler(Looper.getMainLooper())
    private val backgroundExecutor = Executors.newCachedThreadPool()

    private var eventSink: EventChannel.EventSink? = null

    private data class PlayerInstance(
        val id: Int,
        val player: ExoPlayer,
        val textureEntry: TextureRegistry.SurfaceTextureEntry,
        val streamHandle: Long,
        val surface: Surface
    )

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
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
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        players.keys.toList().forEach { disposePlayer(it) }
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
            handler.post { createPlayerWithUri(playerId, cdnUrl) }
        } else {
            CryptoNative.ensureInit()
            backgroundExecutor.execute {
                val streamHandle = CryptoNative.nativePlayerStreamOpen(cdnUrl, keyHex)
                if (streamHandle == 0L) {
                    sendEvent(playerId, "error", "sp_stream_open failed")
                    return@execute
                }
                handler.post { createPlayerWithCrypto(playerId, cdnUrl, keyHex, streamHandle) }
            }
        }
    }

    private fun createPlayerWithUri(playerId: Int, uri: String) {
        val textureEntry = textureRegistry.createSurfaceTexture()
        val surface = Surface(textureEntry.surfaceTexture())

        val player = ExoPlayer.Builder(flutterBinding.applicationContext).build()
        player.setVideoSurface(surface)

        val mediaItem = MediaItem.fromUri(uri)
        player.setMediaItem(mediaItem)
        player.prepare()

        setupPlayerListener(playerId, player)

        val instance = PlayerInstance(playerId, player, textureEntry, 0L, surface)
        players[playerId] = instance
        sendEvent(playerId, "created", textureEntry.id())
    }

    private fun createPlayerWithCrypto(
        playerId: Int, cdnUrl: String, keyHex: String, streamHandle: Long
    ) {
        val textureEntry = textureRegistry.createSurfaceTexture()
        val surface = Surface(textureEntry.surfaceTexture())

        val player = ExoPlayer.Builder(flutterBinding.applicationContext).build()
        player.setVideoSurface(surface)

        val dataSourceFactory = DataSource.Factory {
            CryptoDataSource(cdnUrl, keyHex)
        }
        val mediaSource = ProgressiveMediaSource.Factory(dataSourceFactory)
            .createMediaSource(MediaItem.fromUri("crypto://$cdnUrl"))
        player.setMediaSource(mediaSource)
        player.prepare()

        setupPlayerListener(playerId, player)

        val instance = PlayerInstance(playerId, player, textureEntry, streamHandle, surface)
        players[playerId] = instance
        sendEvent(playerId, "created", textureEntry.id())
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
                    Player.STATE_ENDED -> sendEvent(playerId, "completed", true)
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
                    handler.post {
                        eventSink?.success(mapOf(
                            "playerId" to playerId,
                            "type" to "videoSize",
                            "width" to videoSize.width,
                            "height" to videoSize.height
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
        })
    }

    private fun startPositionUpdates(playerId: Int) {
        handler.post(object : Runnable {
            override fun run() {
                val instance = players[playerId] ?: return
                val player = instance.player
                if (player.isPlaying) {
                    sendEvent(playerId, "position", player.currentPosition)
                    handler.postDelayed(this, 200)
                }
            }
        })
    }

    private fun sendEvent(playerId: Int, type: String, value: Any) {
        handler.post {
            eventSink?.success(mapOf("playerId" to playerId, "type" to type, "value" to value))
        }
    }

    private fun disposePlayer(id: Int) {
        val instance = players.remove(id) ?: return
        instance.player.release()
        instance.surface.release()
        instance.textureEntry.release()
        val handle = instance.streamHandle
        if (handle != 0L) {
            backgroundExecutor.execute {
                CryptoNative.nativePlayerStreamClose(handle)
            }
        }
    }

    private inner class CryptoDataSource(
        private val cdnUrl: String,
        private val keyHex: String
    ) : BaseDataSource(true) {

        private var streamHandle: Long = 0L
        private var uri: Uri? = null
        private var bytesRemaining: Long = C.LENGTH_UNSET.toLong()

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
            val tempBuf = ByteArray(toRead)
            val bytesRead = CryptoNative.nativePlayerStreamRead(streamHandle, tempBuf, toRead)
            if (bytesRead <= 0) return C.RESULT_END_OF_INPUT
            System.arraycopy(tempBuf, 0, buffer, offset, bytesRead)
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
            transferEnded()
        }
    }
}
