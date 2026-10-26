package com.fqapp.fqapp

import android.content.Context
import android.content.BroadcastReceiver
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

// Note: .agents/notes/implemented/feature/2026-10-15-system-tts.md
// One engine belongs to the app listening session, never to an Activity/page.
class SystemTtsPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private lateinit var context: Context
    private lateinit var methods: MethodChannel
    private lateinit var events: EventChannel
    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private var tts: TextToSpeech? = null
    private var pending: MethodChannel.Result? = null
    private var timeout: Runnable? = null
    private var generation = 0
    private var activeId: String? = null
    // Every utterance the engine still owns. The reader queues a sentence ahead,
    // so callbacks can arrive for more than one id at a time.
    private val liveIds = mutableSetOf<String>()
    private var ready = false
    private var focusRequest: AudioFocusRequest? = null
    private var focusListener: AudioManager.OnAudioFocusChangeListener? = null
    private var focusEpoch = 0
    private val attributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_MEDIA)
        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build()
    private val audio get() = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val noisyReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) interrupt()
        }
    }

    private fun interrupt() {
        val id = activeId
        stop()
        // Also cancels a Dart play intent while text or engine is loading.
        sink?.success(mapOf("type" to "interrupted", "id" to id))
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methods = MethodChannel(binding.binaryMessenger, "fqapp/system_tts")
        events = EventChannel(binding.binaryMessenger, "fqapp/system_tts_events")
        methods.setMethodCallHandler(this)
        events.setStreamHandler(this)
        ContextCompat.registerReceiver(context, noisyReceiver,
            IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY), ContextCompat.RECEIVER_NOT_EXPORTED)
    }

    override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink) { sink = eventSink }
    override fun onCancel(arguments: Any?) { sink = null }

    @Suppress("DEPRECATION")
    private fun engines(): List<Map<String, String>> = context.packageManager
        .queryIntentServices(Intent(TextToSpeech.Engine.INTENT_ACTION_TTS_SERVICE), 0)
        .map { mapOf("package" to it.serviceInfo.packageName, "label" to it.loadLabel(context.packageManager).toString()) }
        .distinctBy { it["package"] }.sortedBy { it["label"] }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "engines" -> result.success(mapOf(
                    "engines" to engines(),
                    "defaultEngine" to Settings.Secure.getString(context.contentResolver, Settings.Secure.TTS_DEFAULT_SYNTH)
                ))
                "initialize" -> initialize(call, result)
                "speak" -> {
                    val text = call.argument<String>("text").orEmpty()
                    val id = call.argument<String>("id").orEmpty()
                    // Queued utterances follow the one playing; the first one of
                    // a new position replaces whatever the engine still holds.
                    val queue = call.argument<Boolean>("queue") == true
                    when {
                        !ready -> result.error("not_ready", "朗读引擎尚未就绪", null)
                        text.isBlank() || text.length > TextToSpeech.getMaxSpeechInputLength() || id.isEmpty() ->
                            result.error("invalid_text", "朗读片段为空或过长", null)
                        !requestFocus() -> result.error("audio_focus", "其他应用正在使用音频，请稍后继续", null)
                        else -> {
                            if (!queue) liveIds.clear()
                            liveIds.add(id)
                            activeId = id
                            val mode = if (queue) TextToSpeech.QUEUE_ADD else TextToSpeech.QUEUE_FLUSH
                            if (tts?.speak(text, mode, null, id) == TextToSpeech.SUCCESS) {
                                result.success(null)
                            } else {
                                liveIds.remove(id)
                                stop()
                                result.error("speak_failed", "引擎无法朗读，请检查引擎设置或网络", null)
                            }
                        }
                    }
                }
                "stop" -> { stop(); result.success(null) }
                "shutdown" -> { shutdown(); result.success(null) }
                "settings" -> {
                    try {
                        context.startActivity(Intent("com.android.settings.TTS_SETTINGS").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    } catch (_: android.content.ActivityNotFoundException) {
                        context.startActivity(Intent(Settings.ACTION_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (_: Exception) {
            if (call.method == "initialize") shutdown()
            if (call.method == "speak") stop()
            result.error("tts_failed", "系统朗读不可用，请检查引擎设置后重试", null)
        }
    }

    private fun initialize(call: MethodCall, result: MethodChannel.Result) {
        shutdown()
        val engine = call.argument<String>("engine")?.takeIf { it.isNotBlank() }
        val installed = engines()
        if (installed.isEmpty() || (engine != null && installed.none { it["package"] == engine })) {
            result.error("no_engine", "未找到朗读引擎，请安装或重新选择系统 TTS 引擎", null)
            return
        }
        val rate = (call.argument<Number>("rate")?.toFloat() ?: 1f).coerceIn(0.5f, 3f)
        pending = result
        val token = generation
        timeout = Runnable {
            if (token == generation && pending != null) {
                finishInitError("init_timeout", "朗读引擎启动超时，请打开引擎应用检查配置")
            }
        }.also { main.postDelayed(it, 15000) }
        try {
            tts = TextToSpeech(context, { status ->
                // OnInit may be synchronous on a failed bind; defer until tts is assigned.
                main.post {
                    if (token != generation || pending == null) return@post
                    val instance = tts
                    try {
                        if (status != TextToSpeech.SUCCESS || instance == null) {
                            finishInitError("init_failed", "朗读引擎启动失败，请检查引擎配置")
                            return@post
                        }
                        // Do not silently read Chinese with an unrelated fallback language.
                        if (instance.setLanguage(Locale.SIMPLIFIED_CHINESE) < TextToSpeech.LANG_AVAILABLE) {
                            finishInitError("language_missing", "引擎未提供中文语音，请在引擎中配置中文音色")
                            return@post
                        }
                        instance.setAudioAttributes(attributes)
                        instance.setSpeechRate(rate)
                        instance.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                            override fun onStart(id: String?) = emit(token, id, "start")
                            override fun onDone(id: String?) = emit(token, id, "done")
                            @Deprecated("Deprecated in Java")
                            override fun onError(id: String?) = emit(token, id, "error")
                            override fun onError(id: String?, errorCode: Int) = emit(token, id, "error")
                            override fun onStop(id: String?, interrupted: Boolean) = emit(token, id, "interrupted")
                            override fun onRangeStart(id: String?, start: Int, end: Int, frame: Int) =
                                emit(token, id, "range", start)
                        })
                        ready = true
                        timeout?.let(main::removeCallbacks)
                        timeout = null
                        val reply = pending
                        pending = null
                        reply?.success(TextToSpeech.getMaxSpeechInputLength())
                    } catch (_: Exception) {
                        finishInitError("init_failed", "朗读引擎配置失败，请检查中文音色")
                    }
                }
            }, engine)
        } catch (_: Exception) {
            finishInitError("init_failed", "朗读引擎启动失败，请检查引擎配置")
        }
    }

    private fun finishInitError(code: String, message: String) {
        val reply = pending
        pending = null
        shutdown()
        reply?.error(code, message, null)
    }

    private fun emit(token: Int, id: String?, type: String, start: Int = 0) {
        main.post {
            if (token != generation || id == null || !liveIds.contains(id)) return@post
            sink?.success(mapOf("type" to type, "id" to id, "start" to start))
            if (type == "start") activeId = id
            if (type == "done" || type == "error" || type == "interrupted") liveIds.remove(id)
        }
    }

    @Suppress("DEPRECATION")
    private fun requestFocus(): Boolean {
        if (focusListener != null) return true
        val epoch = ++focusEpoch
        val listener = AudioManager.OnAudioFocusChangeListener { change ->
            if (change != AudioManager.AUDIOFOCUS_GAIN) {
                main.post { if (epoch == focusEpoch) interrupt() }
            }
        }
        val status = if (Build.VERSION.SDK_INT >= 26) {
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(attributes).setWillPauseWhenDucked(true)
                .setOnAudioFocusChangeListener(listener, main).build().also { focusRequest = it }
            audio.requestAudioFocus(request)
        } else {
            audio.requestAudioFocus(listener, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN)
        }
        if (status == AudioManager.AUDIOFOCUS_REQUEST_GRANTED) focusListener = listener
        else stop()
        return status == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
    }

    @Suppress("DEPRECATION")
    private fun stop() {
        focusEpoch++
        activeId = null
        liveIds.clear()
        try { tts?.stop() } catch (_: Exception) { }
        try {
            if (Build.VERSION.SDK_INT >= 26) {
                focusRequest?.let { audio.abandonAudioFocusRequest(it) }
            } else {
                focusListener?.let { audio.abandonAudioFocus(it) }
            }
        } catch (_: Exception) { }
        focusRequest = null
        focusListener = null
    }

    private fun shutdown() {
        generation++
        timeout?.let(main::removeCallbacks)
        timeout = null
        val reply = pending
        pending = null
        reply?.error("cancelled", "已取消启动朗读", null)
        stop()
        ready = false
        try { tts?.shutdown() } catch (_: Exception) { }
        tts = null
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        shutdown()
        context.unregisterReceiver(noisyReceiver)
        sink = null
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
    }
}
