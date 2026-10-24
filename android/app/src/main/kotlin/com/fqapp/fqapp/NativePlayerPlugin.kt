package com.fqapp.fqapp

import android.Manifest
import android.app.Activity
import android.app.ForegroundServiceStartNotAllowedException
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.net.Uri
import android.provider.Settings
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.WindowManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.BaseDataSource
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSourceException
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.HttpDataSource
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.exoplayer.mediacodec.MediaCodecInfo
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector
import androidx.media3.exoplayer.mediacodec.MediaCodecRenderer.DecoderInitializationException
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import com.example.shortplay.CryptoNative
import com.example.shortplay.HttpBridge
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import io.flutter.view.TextureRegistry
import java.io.EOFException
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

/**
 * Native ExoPlayer host for DRM (CENC) short dramas and audiobook audio playback.
 * Decrypted plaintext is served to ExoPlayer through a [CryptoDataSource] backed
 * by the C crypto core; events are pushed to Flutter over an EventChannel.
 */
@androidx.annotation.OptIn(UnstableApi::class)
class NativePlayerPlugin internal constructor(
    private val cryptoStream: CryptoStream = JniCryptoStream,
    private val playerFactory: (Context, VideoDecoderPreference) -> ExoPlayer = { context, decoder ->
        // Note: decoder init fallback and 206 diagnostics — see
        // .agents/notes/implemented/bug-fix/2026-10-15-issue2-decoder-initialization-fallback.md.
        val renderers = DefaultRenderersFactory(context)
            .setEnableDecoderFallback(true)
            // 用户选的解码器策略（issue #92）。自动 = 不干预，MediaTek 部分芯片
            // 在 Android 15 + HEVC + DRM 上硬解静默黑屏（androidx/media#2711），
            // 没有错误回调，只能让用户手动切软解。
            .setMediaCodecSelector(
                when (decoder) {
                    VideoDecoderPreference.SOFTWARE -> SoftwareOnlyCodecSelector
                    VideoDecoderPreference.HARDWARE -> HardwareFirstCodecSelector
                    VideoDecoderPreference.AUTOMATIC -> MediaCodecSelector.DEFAULT
                }
            )
        ExoPlayer.Builder(context, renderers).build()
    }
) : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware,
    PluginRegistry.RequestPermissionsResultListener {

    companion object {
        private const val TAG = "NativePlayerPlugin"
        private const val POST_NOTIFICATIONS_REQUEST = 7412
        @Volatile private var instance: NativePlayerPlugin? = null

        fun dispatchNotificationAction(action: String) {
            instance?.let { plugin ->
                plugin.handler.post {
                    if (plugin.attachedToEngine) {
                        plugin.methodChannel.invokeMethod(
                            "onNotificationAction",
                            mapOf("action" to action)
                        )
                    }
                }
            }
        }
    }

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private lateinit var textureRegistry: TextureRegistry
    private lateinit var flutterBinding: FlutterPlugin.FlutterPluginBinding
    @Volatile private var attachedToEngine = false

    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var notificationPermissionRequested = false
    private val players = ConcurrentHashMap<Int, PlayerInstance>()
    private val pendingPlayerIds = ConcurrentHashMap.newKeySet<Int>()
    private val nextId = AtomicInteger(1)
    private val handler = Handler(Looper.getMainLooper())

    /** 正在悬浮窗里播的播放器；null 表示没有悬浮播放。 */
    private var floatingPlayerId: Int? = null
    private var floatingSurfaceAttached = false
    private var floatingSurface: android.view.Surface? = null
    private var floatingFocusRequest: Any? = null
    private var floatingFocusListener: AudioManager.OnAudioFocusChangeListener? = null
    private var floatingVolumeBeforeDuck: Float? = null

    private var eventSink: EventChannel.EventSink? = null
    private var noisyReceiverRegistered = false

    private val becomingNoisyReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (AudioManager.ACTION_AUDIO_BECOMING_NOISY == intent?.action) {
                players.values.forEach { playerInstance ->
                    try {
                        playerInstance.player.pause()
                    } catch (t: Throwable) {
                        Log.w(TAG, "pause on becoming noisy failed: ${t.javaClass.simpleName}")
                    }
                }
                handler.post {
                    if (attachedToEngine) {
                        methodChannel.invokeMethod("onAudioBecomingNoisy", null)
                    }
                }
            }
        }
    }

    private data class PlayerInstance(
        val id: Int,
        val player: ExoPlayer,
        val videoOutput: NativeVideoOutput,
        val diagnosticUrl: String? = null,
        var positionUpdater: Runnable? = null
    )

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        attachedToEngine = true
        instance = this
        flutterBinding = binding
        // The offline-file bridge only serves file:// URLs inside the app's
        // download/cache trees; configure it before any playback can occur.
        HttpBridge.configure(binding.applicationContext)
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
        activityBinding = binding
        binding.addRequestPermissionsResultListener(this)
    }
    override fun onDetachedFromActivityForConfigChanges() {
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
        activity = null
    }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        activityBinding = binding
        binding.addRequestPermissionsResultListener(this)
    }
    override fun onDetachedFromActivity() {
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
        activity = null
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ): Boolean = requestCode == POST_NOTIFICATIONS_REQUEST

    private fun requestNotificationPermissionIfNeeded() {
        val currentActivity = activity ?: return
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            currentActivity.applicationInfo.targetSdkVersion < Build.VERSION_CODES.TIRAMISU
        ) return
        if (ContextCompat.checkSelfPermission(
                currentActivity,
                Manifest.permission.POST_NOTIFICATIONS
            ) == PackageManager.PERMISSION_GRANTED || notificationPermissionRequested
        ) return
        notificationPermissionRequested = true
        try {
            ActivityCompat.requestPermissions(
                currentActivity,
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                POST_NOTIFICATIONS_REQUEST
            )
        } catch (error: Throwable) {
            notificationPermissionRequested = false
            Log.w(TAG, "notification permission request failed", error)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        attachedToEngine = false
        if (instance === this) instance = null
        stopFloatingInternal()
        FloatingVideoService.onSurfaceReady = null
        FloatingVideoService.onSurfaceDestroyed = null
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
        activity = null
        unregisterNoisyReceiver(binding.applicationContext)
        binding.applicationContext.stopService(
            Intent(binding.applicationContext, ListenKeepAliveService::class.java)
        )
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        players.keys.toList().forEach { id ->
            try {
                disposePlayer(id)
            } catch (error: Throwable) {
                Log.w(TAG, "dispose failed for player $id: ${error.javaClass.simpleName}")
            }
        }
        handler.removeCallbacksAndMessages(null)
        pendingPlayerIds.clear()
        eventSink = null
    }

    private fun registerNoisyReceiver(context: Context) {
        if (!noisyReceiverRegistered) {
            try {
                val filter = IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY)
                context.registerReceiver(becomingNoisyReceiver, filter)
                noisyReceiverRegistered = true
            } catch (t: Throwable) {
                Log.w(TAG, "register noisy receiver failed", t)
            }
        }
    }

    private fun unregisterNoisyReceiver(context: Context) {
        if (noisyReceiverRegistered) {
            try {
                context.unregisterReceiver(becomingNoisyReceiver)
            } catch (t: Throwable) {
                Log.w(TAG, "unregister noisy receiver failed", t)
            }
            noisyReceiverRegistered = false
        }
    }

    /**
     * Required method-call argument. A missing/null argument reports
     * INVALID_ARGUMENT to Dart instead of crashing the plugin on `!!`.
     */
    private fun <T> MethodCall.requiredArgument(name: String, result: MethodChannel.Result): T? {
        val value = argument<T>(name)
        if (value == null) {
            result.error("INVALID_ARGUMENT", "Missing required argument: $name", null)
        }
        return value
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "create" -> {
                val cdnUrl = call.requiredArgument<String>("cdnUrl", result) ?: return
                val keyHex = call.requiredArgument<String>("keyHex", result) ?: return
                // 缺省/未知取值都退化为自动，保持老客户端的默认行为。
                val decoder = VideoDecoderPreference.fromName(
                    call.argument<String>("videoDecoder")
                )
                handleCreate(cdnUrl, keyHex, decoder, result)
            }
            "play" -> {
                val id = call.requiredArgument<Int>("id", result) ?: return
                players[id]?.player?.play()
                result.success(null)
            }
            "pause" -> {
                val id = call.requiredArgument<Int>("id", result) ?: return
                players[id]?.player?.pause()
                result.success(null)
            }
            "seek" -> {
                val id = call.requiredArgument<Int>("id", result) ?: return
                val positionMs = call.requiredArgument<Number>("positionMs", result)?.toLong() ?: return
                players[id]?.player?.seekTo(positionMs)
                result.success(null)
            }
            "setVolume" -> {
                val id = call.requiredArgument<Int>("id", result) ?: return
                val volume = call.requiredArgument<Number>("volume", result)?.toFloat() ?: return
                players[id]?.player?.volume = volume
                result.success(null)
            }
            "setRate" -> {
                val id = call.requiredArgument<Int>("id", result) ?: return
                val rate = call.requiredArgument<Number>("rate", result)?.toFloat() ?: return
                players[id]?.player?.playbackParameters = PlaybackParameters(rate)
                result.success(null)
            }
            "dispose" -> {
                val id = call.requiredArgument<Int>("id", result) ?: return
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
            "startListenForeground" -> {
                val context = activity ?: flutterBinding.applicationContext
                requestNotificationPermissionIfNeeded()
                val intent = Intent(context, ListenKeepAliveService::class.java).apply {
                    putExtra(ListenKeepAliveService.EXTRA_TITLE, call.argument<String>("title"))
                    putExtra(ListenKeepAliveService.EXTRA_EPISODE, call.argument<String>("episode"))
                    // 通知大图与媒体卡封面用当前作品封面（issue #123）。空串时
                    // 服务退回应用图标。
                    putExtra(
                        ListenKeepAliveService.EXTRA_COVER_URL,
                        call.argument<String>("coverUrl"),
                    )
                    putExtra(ListenKeepAliveService.EXTRA_PLAYING, call.argument<Boolean>("playing") ?: true)
                    putExtra(ListenKeepAliveService.EXTRA_HAS_PREV, call.argument<Boolean>("hasPrev") ?: true)
                    putExtra(ListenKeepAliveService.EXTRA_HAS_NEXT, call.argument<Boolean>("hasNext") ?: true)
                    // 进度条与两侧时间全靠这三个值；漏传就等于永远上报 0/0。
                    putExtra(
                        ListenKeepAliveService.EXTRA_POSITION_MS,
                        call.argument<Number>("positionMs")?.toLong() ?: 0L,
                    )
                    putExtra(
                        ListenKeepAliveService.EXTRA_DURATION_MS,
                        call.argument<Number>("durationMs")?.toLong() ?: 0L,
                    )
                    putExtra(
                        ListenKeepAliveService.EXTRA_SPEED,
                        call.argument<Number>("speed")?.toFloat() ?: 1f,
                    )
                }
                try {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        context.startForegroundService(intent)
                    } else {
                        context.startService(intent)
                    }
                    registerNoisyReceiver(context)
                    result.success(null)
                } catch (error: Throwable) {
                    Log.w(TAG, "listen foreground start failed", error)
                    // A swallowed failure used to report success, leaving
                    // Dart believing the keep-alive notification was up while
                    // playback could be frozen by the OEM. Distinguish the
                    // common failure modes so the caller can tell a
                    // background-start ban apart from a permission/state error.
                    // (Dart treats this call as best-effort and catches the
                    // error; see NativePlayer.startListenForeground.)
                    val code = when {
                        Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                            error is ForegroundServiceStartNotAllowedException ->
                            "FOREGROUND_SERVICE_NOT_ALLOWED"
                        error is SecurityException -> "FOREGROUND_SERVICE_SECURITY"
                        error is IllegalStateException -> "FOREGROUND_SERVICE_STATE"
                        else -> "FOREGROUND_SERVICE_FAILED"
                    }
                    result.error(
                        code,
                        "Failed to start listen foreground service: ${error.javaClass.simpleName}",
                        null,
                    )
                }
            }
            "stopListenForeground" -> {
                val context = activity ?: flutterBinding.applicationContext
                try {
                    context.stopService(Intent(context, ListenKeepAliveService::class.java))
                    unregisterNoisyReceiver(context)
                } catch (error: Throwable) {
                    Log.w(TAG, "listen foreground stop failed", error)
                }
                result.success(null)
            }
            "canDrawOverlays" -> {
                val context = activity ?: flutterBinding.applicationContext
                result.success(
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        Settings.canDrawOverlays(context)
                    } else {
                        true
                    },
                )
            }
            "requestOverlayPermission" -> {
                val currentActivity = activity
                if (currentActivity == null ||
                    Build.VERSION.SDK_INT < Build.VERSION_CODES.M
                ) {
                    result.success(false)
                    return
                }
                try {
                    val intent = Intent(
                        Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                        Uri.parse("package:${currentActivity.packageName}"),
                    )
                    currentActivity.startActivity(intent)
                    result.success(true)
                } catch (error: Throwable) {
                    Log.w(TAG, "overlay permission request failed", error)
                    result.success(false)
                }
            }
            "startFloating" -> {
                val id = call.argument<Int>("playerId")
                val instance = id?.let { players[it] }
                if (instance == null) {
                    result.error("FLOATING_NO_PLAYER", "悬浮窗播放器不存在", null)
                    return
                }
                if (!requestFloatingFocus()) {
                    // 焦点被电话等独占时不抢声，交给 Dart 侧暂停。
                    floatingFocusListener = null
                    floatingFocusRequest = null
                    result.error("FLOATING_FOCUS_DENIED", "音频焦点被占用，暂不悬浮", null)
                    return
                }
                floatingPlayerId = id
                FloatingVideoService.onSurfaceReady = { surface ->
                    handler.post { onFloatingSurfaceReady(surface) }
                }
                FloatingVideoService.onSurfaceDestroyed = {
                    handler.post { onFloatingSurfaceDestroyed() }
                }
                val extras = mapOf<String, Any?>(
                    FloatingVideoService.EXTRA_TITLE to call.argument<String>("title"),
                    FloatingVideoService.EXTRA_EPISODE to call.argument<String>("episode"),
                    FloatingVideoService.EXTRA_PLAYING to
                        (call.argument<Boolean>("playing") ?: true),
                    FloatingVideoService.EXTRA_HAS_PREV to
                        (call.argument<Boolean>("hasPrev") ?: true),
                    FloatingVideoService.EXTRA_HAS_NEXT to
                        (call.argument<Boolean>("hasNext") ?: true),
                    FloatingVideoService.EXTRA_POSITION_MS to
                        (call.argument<Number>("positionMs")?.toLong() ?: 0L),
                    FloatingVideoService.EXTRA_DURATION_MS to
                        (call.argument<Number>("durationMs")?.toLong() ?: 0L),
                    FloatingVideoService.EXTRA_SPEED to
                        (call.argument<Number>("speed")?.toFloat() ?: 1f),
                    FloatingVideoService.EXTRA_VIDEO_WIDTH to
                        (call.argument<Number>("videoWidth")?.toInt() ?: 0),
                    FloatingVideoService.EXTRA_VIDEO_HEIGHT to
                        (call.argument<Number>("videoHeight")?.toInt() ?: 0),
                )
                try {
                    FloatingVideoService.start(
                        activity ?: flutterBinding.applicationContext,
                        extras,
                    )
                    result.success(null)
                } catch (error: Throwable) {
                    Log.w(TAG, "floating start failed", error)
                    stopFloatingInternal()
                    result.error("FLOATING_START_FAILED", "悬浮窗启动失败", null)
                }
            }
            "showFloating" -> {
                try {
                    FloatingVideoService.show(activity ?: flutterBinding.applicationContext)
                } catch (error: Throwable) {
                    Log.w(TAG, "floating show failed", error)
                }
                result.success(null)
            }
            "updateFloating" -> {
                val extras = mapOf<String, Any?>(
                    FloatingVideoService.EXTRA_TITLE to call.argument<String>("title"),
                    FloatingVideoService.EXTRA_EPISODE to call.argument<String>("episode"),
                    FloatingVideoService.EXTRA_PLAYING to call.argument<Boolean>("playing"),
                    FloatingVideoService.EXTRA_HAS_PREV to call.argument<Boolean>("hasPrev"),
                    FloatingVideoService.EXTRA_HAS_NEXT to call.argument<Boolean>("hasNext"),
                    FloatingVideoService.EXTRA_POSITION_MS to
                        call.argument<Number>("positionMs")?.toLong(),
                    FloatingVideoService.EXTRA_DURATION_MS to
                        call.argument<Number>("durationMs")?.toLong(),
                    FloatingVideoService.EXTRA_SPEED to
                        call.argument<Number>("speed")?.toFloat(),
                )
                try {
                    FloatingVideoService.update(
                        activity ?: flutterBinding.applicationContext,
                        extras,
                    )
                } catch (error: Throwable) {
                    Log.w(TAG, "floating update failed", error)
                }
                result.success(null)
            }
            "stopFloating" -> {
                stopFloatingInternal()
                result.success(null)
            }
            "swapFloatingPlayer" -> {
                // 后台自动切集：旧播放器已销毁，新播放器接手悬浮窗。服务不重启，
                // 避免在后台触发前台服务启动限制；只换 surface 绑定。
                val id = call.argument<Int>("playerId")
                val instance = id?.let { players[it] }
                val surface = floatingSurface
                if (instance == null || surface == null) {
                    result.error("FLOATING_SWAP_FAILED", "悬浮窗 surface 不可用", null)
                    return
                }
                floatingPlayerId = id
                try {
                    instance.videoOutput.detachForFloating()
                    instance.videoOutput.attachFloating(surface)
                    floatingSurfaceAttached = true
                    result.success(null)
                } catch (error: Throwable) {
                    Log.w(TAG, "floating swap failed", error)
                    result.error("FLOATING_SWAP_FAILED", "悬浮窗接手失败", null)
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun handleCreate(
        cdnUrl: String,
        keyHex: String,
        decoder: VideoDecoderPreference,
        result: MethodChannel.Result
    ) {
        // Note: deferred CDN I/O — see .agents/notes/implemented/bug-fix/2026-09-17-reviewed-runtime-boundaries.md.
        val playerId = nextId.getAndIncrement()
        pendingPlayerIds.add(playerId)
        result.success(mapOf("playerId" to playerId, "textureId" to -1))

        if (keyHex.isEmpty()) {
            handler.post {
                createPlayerWithUri(playerId, cdnUrl, decoder)
            }
        } else {
            try {
                cryptoStream.ensureInitialized()
                // Media3 opens and validates the stream on its loader thread.
                // A separate probe repeats all metadata I/O and cannot be
                // cancelled while the native open is still obtaining a handle.
                handler.post {
                    createPlayerWithCrypto(playerId, cdnUrl, keyHex, decoder)
                }
            } catch (_: Throwable) {
                failCreation(playerId)
            }
        }
    }

    private fun failCreation(playerId: Int) {
        if (pendingPlayerIds.remove(playerId)) {
            sendEvent(playerId, "error", mapOf("message" to "Player creation failed"))
        }
    }

    private fun createPlayerWithUri(
        playerId: Int,
        uri: String,
        decoder: VideoDecoderPreference
    ) {
        createPlayer(playerId, decoder) { player ->
            player.setMediaItem(MediaItem.fromUri(uri))
        }
    }

    private fun createPlayerWithCrypto(
        playerId: Int,
        cdnUrl: String,
        keyHex: String,
        decoder: VideoDecoderPreference
    ) {
        cryptoStream.clearHttpStatus(cdnUrl)
        createPlayer(playerId, decoder, cdnUrl) { player ->
            val dataSourceFactory = DataSource.Factory {
                CryptoDataSource(cdnUrl, keyHex, cryptoStream)
            }
            val mediaSource = ProgressiveMediaSource.Factory(dataSourceFactory)
                .createMediaSource(MediaItem.fromUri("crypto://$cdnUrl"))
            player.setMediaSource(mediaSource)
        }
    }

    private fun createPlayer(
        playerId: Int,
        decoder: VideoDecoderPreference,
        diagnosticUrl: String? = null,
        configure: (ExoPlayer) -> Unit
    ) {
        if (!attachedToEngine || !pendingPlayerIds.remove(playerId)) return
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
            player = playerFactory(flutterBinding.applicationContext, decoder)
            output = NativeVideoOutput(player, producer)
            players[playerId] = PlayerInstance(playerId, player, output, diagnosticUrl)
            output.attach()
            setupPlayerListener(playerId, player, diagnosticUrl)
            configure(player)
            player.prepare()
            sendEvent(playerId, "created", output.textureId)
        } catch (_: Throwable) {
            players.remove(playerId)
            if (output != null) {
                try {
                    output.release()
                } catch (releaseError: Throwable) {
                    android.util.Log.w(
                        TAG,
                        "output cleanup failed: ${releaseError.javaClass.simpleName}"
                    )
                }
            } else {
                try {
                    player?.release()
                } catch (releaseError: Throwable) {
                    android.util.Log.w(
                        TAG,
                        "player cleanup failed: ${releaseError.javaClass.simpleName}"
                    )
                } finally {
                    try {
                        producer?.release()
                    } catch (releaseError: Throwable) {
                        android.util.Log.w(
                            TAG,
                            "producer cleanup failed: ${releaseError.javaClass.simpleName}"
                        )
                    }
                }
            }
            diagnosticUrl?.let(cryptoStream::clearHttpStatus)
            sendEvent(playerId, "error", mapOf("message" to "Player creation failed"))
        }
    }

    private fun setupPlayerListener(playerId: Int, player: ExoPlayer, diagnosticUrl: String?) {
        var firstFrameSent = false

        player.addAnalyticsListener(object : AnalyticsListener {
            override fun onVideoDecoderInitialized(
                eventTime: AnalyticsListener.EventTime,
                decoderName: String,
                initializedTimestampMs: Long,
                initializationDurationMs: Long
            ) {
                sendEvent(playerId, "decoderInitialized", mapOf("name" to decoderName))
                if (isSoftwareDecoder(decoderName)) {
                    maybeSwapToSurfaceTexture(playerId)
                }
            }
        })

        player.addListener(object : Player.Listener {
            override fun onPlaybackStateChanged(playbackState: Int) {
                when (playbackState) {
                    Player.STATE_BUFFERING -> sendEvent(playerId, "buffering", true)
                    Player.STATE_READY -> {
                        sendEvent(playerId, "buffering", false)
                        // 时长此刻常常还没拿到（C.TIME_UNSET）；真拿到才发，Dart 侧才认。
                        if (player.duration != C.TIME_UNSET) {
                            sendEvent(playerId, "duration", player.duration)
                        }
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

            override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
                // isPlaying becomes false during buffering without a pause.
                // Flutter needs the separate intent to resume after backgrounding.
                sendEvent(playerId, "playWhenReady", playWhenReady)
            }

            override fun onVideoSizeChanged(videoSize: VideoSize) {
                if (videoSize.width > 0 && videoSize.height > 0) {
                    val instance = players[playerId] ?: return
                    // Media3 reports display width/height after rotation. Its
                    // ImageReader output still needs the format rotation in
                    // Flutter; SurfaceTexture producers already apply it.
                    val formatRotation = player.videoFormat?.rotationDegrees ?: 0
                    val rotation = instance.videoOutput.rotationCorrection(formatRotation)
                    handler.post {
                        if (!attachedToEngine || players[playerId] !== instance) return@post
                        eventSink?.success(mapOf(
                            "playerId" to playerId,
                            "type" to "videoSize",
                            "width" to videoSize.width,
                            "height" to videoSize.height,
                            "rotationCorrection" to rotation,
                            // 诊断（issue #11）：区分「producer 已代理旋转」与
                            // 「需要 Flutter 自己转」两条路径，避免靠猜。
                            "formatRotation" to formatRotation,
                            "handlesCropAndRotation" to
                                instance.videoOutput.handlesCropAndRotation()
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
                        "message" to "Playback failed",
                        "errorCode" to error.errorCode,
                        "httpStatusCode" to (httpError?.responseCode
                            ?: diagnosticUrl?.let(cryptoStream::lastHttpStatus)),
                        "decoder" to decoderDiagnostics(error)
                    )
                )
            }
        })
    }

    private fun decoderDiagnostics(error: Throwable): Map<String, Any?>? {
        val failure = generateSequence(error) { it.cause }
            .take(8)
            .filterIsInstance<DecoderInitializationException>()
            .firstOrNull() ?: return null
        // Only codec metadata crosses the bridge. Exception messages and Format
        // dumps may contain media identifiers or URLs and are deliberately omitted.
        return mapOf(
            "name" to failure.codecInfo?.name,
            "mimeType" to failure.mimeType,
            "diagnosticInfo" to failure.diagnosticInfo,
            "fallbackDecoders" to generateSequence(failure.fallbackDecoderInitializationException) {
                it.fallbackDecoderInitializationException
            }.take(8).mapNotNull { it.codecInfo?.name }.toList()
        )
    }

    private fun startPositionUpdates(playerId: Int) {
        val instance = players[playerId] ?: return
        instance.positionUpdater?.let(handler::removeCallbacks)
        // 时长常常在 STATE_READY 之后才拿到（那一刻上报的是 C.TIME_UNSET），而 STATE_READY
        // 每个媒体项只来一次——所以这里补发「真的拿到了」的时长，否则系统媒体卡片右侧
        // 永远是 00:00。
        var reportedDurationMs = -1L
        val updater = object : Runnable {
            override fun run() {
                val current = players[playerId] ?: return
                val player = current.player
                if (player.isPlaying) {
                    sendEvent(playerId, "position", player.currentPosition)
                    val durationMs = player.duration
                    if (durationMs != C.TIME_UNSET &&
                        durationMs > 0 &&
                        durationMs != reportedDurationMs
                    ) {
                        reportedDurationMs = durationMs
                        sendEvent(playerId, "duration", durationMs)
                    }
                    handler.postDelayed(this, 200)
                } else {
                    current.positionUpdater = null
                }
            }
        }
        instance.positionUpdater = updater
        handler.post(updater)
    }

    private fun maybeSwapToSurfaceTexture(playerId: Int) {
        val instance = players[playerId] ?: return
        handler.post {
            if (!attachedToEngine || players[playerId] !== instance) return@post
            try {
                val newTextureId =
                    instance.videoOutput.swapToSurfaceTexture(textureRegistry)
                if (newTextureId != null) {
                    sendEvent(playerId, "textureChanged", newTextureId)
                }
            } catch (error: Throwable) {
                Log.w(TAG, "surface texture swap failed for player $playerId", error)
            }
        }
    }

    private fun sendEvent(playerId: Int, type: String, value: Any) {
        handler.post {
            if (attachedToEngine) {
                eventSink?.success(mapOf("playerId" to playerId, "type" to type, "value" to value))
            }
        }
    }

    /**
     * 悬浮窗 surface 就绪：把解码画面从 Flutter 纹理换到悬浮窗。
     * 只在仍处于悬浮状态时换，迟到的回调（服务已停）直接丢弃。
     */
    private fun onFloatingSurfaceReady(surface: android.view.Surface) {
        floatingSurface = surface
        val id = floatingPlayerId ?: return
        val instance = players[id] ?: return
        try {
            instance.videoOutput.detachForFloating()
            instance.videoOutput.attachFloating(surface)
            floatingSurfaceAttached = true
        } catch (error: Throwable) {
            Log.w(TAG, "floating surface attach failed", error)
        }
    }

    /** 悬浮窗 surface 销毁：画面回落到 Flutter 纹理，声音继续（服务还在就还在）。 */
    private fun onFloatingSurfaceDestroyed() {
        floatingSurface = null
        val id = floatingPlayerId ?: return
        if (!floatingSurfaceAttached) return
        floatingSurfaceAttached = false
        try {
            players[id]?.videoOutput?.restoreFromFloating()
        } catch (error: Throwable) {
            Log.w(TAG, "floating surface restore failed", error)
        }
    }

    /** 停悬浮：画面先回 Flutter 纹理，再停服务，避免销毁回调重复恢复。 */
    private fun stopFloatingInternal() {
        val id = floatingPlayerId
        floatingPlayerId = null
        floatingSurface = null
        abandonFloatingFocus()
        if (id != null && floatingSurfaceAttached) {
            floatingSurfaceAttached = false
            try {
                players[id]?.videoOutput?.restoreFromFloating()
            } catch (error: Throwable) {
                Log.w(TAG, "floating restore failed", error)
            }
        }
        FloatingVideoService.onSurfaceReady = null
        FloatingVideoService.onSurfaceDestroyed = null
        try {
            FloatingVideoService.stop(flutterBinding.applicationContext)
        } catch (error: Throwable) {
            Log.w(TAG, "floating stop failed", error)
        }
    }

    /**
     * 悬浮播放期间独占音频焦点：电话、其他媒体进来时暂停而不是混音；
     * 短暂可降音（duck）时只降音量，焦点回来后恢复音量、但不自动续播。
     */
    private fun requestFloatingFocus(): Boolean {
        val context = flutterBinding.applicationContext
        val audioManager =
            context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
                ?: return false
        val listener = AudioManager.OnAudioFocusChangeListener { change ->
            val id = floatingPlayerId ?: return@OnAudioFocusChangeListener
            val instance = players[id] ?: return@OnAudioFocusChangeListener
            when (change) {
                AudioManager.AUDIOFOCUS_LOSS,
                AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                    try {
                        instance.player.pause()
                    } catch (_: Throwable) {
                    }
                    FloatingVideoService.update(
                        context,
                        mapOf(FloatingVideoService.EXTRA_PLAYING to false),
                    )
                }
                AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
                    if (floatingVolumeBeforeDuck == null) {
                        floatingVolumeBeforeDuck = instance.player.volume
                        try {
                            instance.player.volume =
                                (instance.player.volume * 0.2f).coerceIn(0f, 1f)
                        } catch (_: Throwable) {
                        }
                    }
                }
                AudioManager.AUDIOFOCUS_GAIN -> {
                    floatingVolumeBeforeDuck?.let { volume ->
                        floatingVolumeBeforeDuck = null
                        try {
                            instance.player.volume = volume
                        } catch (_: Throwable) {
                        }
                    }
                }
            }
        }
        floatingFocusListener = listener
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                        .build(),
                )
                .setOnAudioFocusChangeListener(listener)
                .build()
            floatingFocusRequest = request
            audioManager.requestAudioFocus(request) ==
                AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        } else {
            @Suppress("DEPRECATION")
            audioManager.requestAudioFocus(
                listener,
                AudioManager.STREAM_MUSIC,
                AudioManager.AUDIOFOCUS_GAIN,
            ) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        }
    }

    private fun abandonFloatingFocus() {
        val listener = floatingFocusListener
        floatingFocusListener = null
        floatingVolumeBeforeDuck = null
        val context = flutterBinding.applicationContext
        // 单元测试的 mock Context 不提供系统服务；缺 AudioManager 时只是没有
        // 焦点可放弃，不能让 detach 抛异常。
        val audioManager =
            context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return
        val request = floatingFocusRequest
        floatingFocusRequest = null
        if (request != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            try {
                audioManager.abandonAudioFocusRequest(request as AudioFocusRequest)
            } catch (_: Throwable) {
            }
        } else if (listener != null) {
            @Suppress("DEPRECATION")
            try {
                audioManager.abandonAudioFocus(listener)
            } catch (_: Throwable) {
            }
        }
    }

    private fun disposePlayer(id: Int) {
        if (id == floatingPlayerId) {
            // 悬浮播放器销毁（通常是后台自动切集）：服务与悬浮窗留着，等 Dart
            // 用 swapFloatingPlayer 把新播放器接进来；页面关闭时 Dart 会
            // 显式调 stopFloating，不会留下幽灵窗口。
            floatingPlayerId = null
            floatingSurfaceAttached = false
        }
        // Only a still-pending request may allocate. A queued create callback
        // must stay cancelled even if the platform thread stalls.
        pendingPlayerIds.remove(id)
        val instance = players.remove(id) ?: return
        instance.positionUpdater?.let(handler::removeCallbacks)
        instance.diagnosticUrl?.let(cryptoStream::clearHttpStatus)
        // A throwing release must not abort the remaining teardown steps.
        try {
            instance.videoOutput.release()
        } catch (error: Throwable) {
            android.util.Log.w(
                TAG,
                "release failed for player $id: ${error.javaClass.simpleName}"
            )
        }
    }

    internal class CryptoDataSource(
        private val cdnUrl: String,
        private val keyHex: String,
        private val stream: CryptoStream = JniCryptoStream
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
            transferInitializing(dataSpec)
            try {
                streamHandle = stream.open(cdnUrl, keyHex)
                if (streamHandle == 0L) {
                    throw IOException("Failed to open crypto stream")
                }
                val totalSize = stream.size(streamHandle)
                if (totalSize > 0 && dataSpec.position > totalSize) {
                    throw DataSourceException(PlaybackException.ERROR_CODE_IO_READ_POSITION_OUT_OF_RANGE)
                }
                val available = if (totalSize > 0) totalSize - dataSpec.position else C.LENGTH_UNSET.toLong()
                bytesRemaining = when {
                    dataSpec.length == C.LENGTH_UNSET.toLong() -> available
                    available == C.LENGTH_UNSET.toLong() -> dataSpec.length
                    else -> minOf(available, dataSpec.length)
                }
                if (dataSpec.position > 0 && bytesRemaining != 0L) {
                    if (stream.seek(streamHandle, dataSpec.position) != dataSpec.position) {
                        throw IOException("Crypto stream could not seek to the requested position")
                    }
                }
                opened = true
                transferStarted(dataSpec)
                return bytesRemaining
            } catch (error: Throwable) {
                close()
                throw error
            }
        }

        override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
            if (length == 0) return 0
            if (bytesRemaining == 0L) return C.RESULT_END_OF_INPUT
            // JNI and the C stream return at most 64 KiB per read. A large
            // extractor request must not retain an equally large scratch array.
            // Note: .agents/notes/implemented/bug-fix/2026-09-17-persistent-data-and-web-cancellation.md
            val boundedLength = minOf(length, 64 * 1024)
            val toRead = if (bytesRemaining != C.LENGTH_UNSET.toLong()) {
                minOf(boundedLength.toLong(), bytesRemaining).toInt()
            } else {
                boundedLength
            }
            var tmp = readBuffer
            if (tmp == null || tmp.size < toRead) {
                tmp = ByteArray(toRead)
                readBuffer = tmp
            }
            val bytesRead = stream.read(streamHandle, tmp, toRead)
            if (bytesRead <= 0) {
                // A known resource/request length must be fulfilled. Reporting
                // an early network failure as EOF can make ExoPlayer mark the
                // episode completed and skip to the next one.
                if (bytesRemaining != C.LENGTH_UNSET.toLong()) {
                    throw EOFException("Crypto stream ended before the expected length")
                }
                return C.RESULT_END_OF_INPUT
            }
            System.arraycopy(tmp, 0, buffer, offset, bytesRead)
            if (bytesRemaining != C.LENGTH_UNSET.toLong()) {
                bytesRemaining -= bytesRead
            }
            bytesTransferred(bytesRead)
            return bytesRead
        }

        override fun getUri(): Uri? = uri

        override fun close() {
            val handle = streamHandle
            streamHandle = 0L
            uri = null
            try {
                if (handle != 0L) stream.close(handle)
            } finally {
                if (opened) {
                    opened = false
                    transferEnded()
                }
            }
        }
    }
}

/**
 * AOSP software decoders (OMX.google.* / c2.android.*) report stride-padded
 * buffers whose padding Flutter's ImageReader texture path draws as a green
 * bar (issue #2). Hardware decoders keep their vendor prefixes
 * (OMX.qcom.* / OMX.Exynos.* / OMX.MTK.* / c2.qti.* / OMX.hisi.* …).
 */
internal fun isSoftwareDecoder(decoderName: String): Boolean =
    decoderName.startsWith("OMX.google.") || decoderName.startsWith("c2.android.")

/** 用户选择的视频解码器策略（与 Dart 侧 `VideoDecoderPreference` 同名）。 */
internal enum class VideoDecoderPreference {
    AUTOMATIC, HARDWARE, SOFTWARE;

    companion object {
        fun fromName(value: String?): VideoDecoderPreference =
            entries.firstOrNull { it.name.equals(value, ignoreCase = true) } ?: AUTOMATIC
    }
}

/**
 * 只保留 AOSP 软解码器，用于 [VideoDecoderPreference.SOFTWARE]。
 *
 * 部分 MediaTek 芯片在 Android 15 上播 HEVC + 加密内容时硬解静默黑屏或卡帧，
 * 且不抛任何错误（androidx/media#2711、Google issue 437738589），
 * `setEnableDecoderFallback` 因此永远不会被触发。用户手动选软解时走这里。
 *
 * 过滤规则与 [isSoftwareDecoder] 一致，避免两处判断漂移。过滤后为空时退回默认
 * 列表，让 ExoPlayer 自己报无可用解码器，而不是静默不给候选。
 */
internal object SoftwareOnlyCodecSelector : MediaCodecSelector {
    override fun getDecoderInfos(
        mimeType: String,
        requiresSecureDecoder: Boolean,
        requiresTunnelingDecoder: Boolean
    ): List<MediaCodecInfo> {
        val all = MediaCodecSelector.DEFAULT
            .getDecoderInfos(mimeType, requiresSecureDecoder, requiresTunnelingDecoder)
        val software = all.filter { isSoftwareDecoder(it.name) }
        return software.ifEmpty { all }
    }
}

/**
 * 硬解优先：把系统软解码器排到后面，用于 [VideoDecoderPreference.HARDWARE]。
 *
 * 与 [MediaCodecSelector.DEFAULT] 的唯一差别是排序，不删除任何候选——硬解真的
 * 不可用时仍能回落到软解。
 */
internal object HardwareFirstCodecSelector : MediaCodecSelector {
    override fun getDecoderInfos(
        mimeType: String,
        requiresSecureDecoder: Boolean,
        requiresTunnelingDecoder: Boolean
    ): List<MediaCodecInfo> {
        val all = MediaCodecSelector.DEFAULT
            .getDecoderInfos(mimeType, requiresSecureDecoder, requiresTunnelingDecoder)
        return all.filterNot { isSoftwareDecoder(it.name) } +
            all.filter { isSoftwareDecoder(it.name) }
    }
}
/** Injectable JNI boundary for creation and DataSource range/error checks on the JVM. */
internal interface CryptoStream {
    fun ensureInitialized()
    fun open(url: String, keyHex: String): Long
    fun size(handle: Long): Long
    fun seek(handle: Long, position: Long): Long
    fun read(handle: Long, buffer: ByteArray, length: Int): Int
    fun close(handle: Long)
    fun lastHttpStatus(url: String): Int? = null
    fun clearHttpStatus(url: String) {}
}

private object JniCryptoStream : CryptoStream {
    override fun ensureInitialized() = CryptoNative.ensureInit()
    override fun open(url: String, keyHex: String) = CryptoNative.nativePlayerStreamOpen(url, keyHex)
    override fun size(handle: Long) = CryptoNative.nativePlayerStreamSize(handle)
    override fun seek(handle: Long, position: Long) = CryptoNative.nativePlayerStreamSeek(handle, position)
    override fun read(handle: Long, buffer: ByteArray, length: Int) =
        CryptoNative.nativePlayerStreamRead(handle, buffer, length)
    override fun close(handle: Long) = CryptoNative.nativePlayerStreamClose(handle)
    override fun lastHttpStatus(url: String) = com.example.shortplay.HttpBridge.lastHttpStatus(url)
    override fun clearHttpStatus(url: String) = com.example.shortplay.HttpBridge.clearHttpStatus(url)
}
