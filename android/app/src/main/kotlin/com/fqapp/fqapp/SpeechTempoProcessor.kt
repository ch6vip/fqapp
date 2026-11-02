package com.fqapp.fqapp

import android.util.Log
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.BaseAudioProcessor
import androidx.media3.common.util.UnstableApi
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * 听书倍速的时伸缩（issue #129），对齐番茄 7.0.9.32 的做法。
 *
 * 官方在 native 层用 FFmpeg 的 `atempo` 滤镜（`avfilter_get_by_name("atempo")`、
 * 参数 `tempo=%1.2f`、`aformat -> atempo -> abuffersink`），窗口
 * `sample_rate / 24`、Hann 窗重叠相加、FFT 互相关对齐。Media3 自带的
 * `SonicAudioProcessor` 是另一套实现（AMDF 基频搜索），高倍速下听感更「电」。
 *
 * 这里直接调用移植过来的同一份 WSOLA（`libshortplay_tempo.so`），参数与官方
 * 逐项一致，因此听感应当与官方对齐。
 *
 * 只在听书（纯音频）播放器上启用；视频播放器仍走 Media3 内建变速。
 *
 * 数据流：queueInput 累积到一整块后交给 native，native 可能一次吃不完
 * （需要更多输入才能产出一帧），所以 input 与 output 各自只有一个缓冲，
 * 由 pendingInput / pendingOutput 表达「还没吃完 / 还没取走」。
 */
@OptIn(UnstableApi::class)
internal class SpeechTempoProcessor(
    initialSpeed: Float = 1f,
    /**
     * 变速前要统一到的采样率，由外部按官方 `getNativeOutputSampleRate()`
     * 的等价物（Media3 的 `AudioCapabilities`）传进来。0 表示未知，
     * 退化为「不做重采样」，只按输入采样率跑 WSOLA。
     */
    private val targetSampleRate: Int = 0,
) : BaseAudioProcessor() {

    /** 真实采样率要到 configure 才知道（WSOLA 的窗口由它决定）。 */
    private var sampleRateHz: Int = 0
    private var channelCount: Int = 0

    /** 实际使用的统一采样率：目标未知时保持输入采样率不变。 */
    private val resolvedTargetRate: Int
        get() = if (targetSampleRate > 0) targetSampleRate else sampleRateHz

    private companion object {
        const val TAG = "SpeechTempoProcessor"

        /** Bound each newly preprocessed native chunk; output can span multiple calls. */
        const val CHUNK_BYTES = 8 * 1024

        /** JNI process uses an aligned unsigned16 capacity; flush uses the full buffer. */
        const val OUTPUT_CAPACITY = 64 * 1024

    }

    private var handle: Int = 0
    private var speed: Float = initialSpeed
    private var inputEnded = false

    /** 还没被 native 吃完的输入。 */
    private var pendingInput: ByteBuffer = AudioProcessor.EMPTY_BUFFER

    /** native 产出但还没被下游取走的输出。 */
    private var pendingOutput: ByteBuffer = AudioProcessor.EMPTY_BUFFER

    private val frameBytes: Int get() = 2 * channelCount

    private fun openHandle() {
        handle = SpeechTempo.createChain(
            sampleRateHz,
            channelCount,
            speed.toDouble(),
            // 官方在 atempo 之前把 PCM 统一到**设备原生输出采样率**
            // （`getNativeOutputSampleRate()` + samplefilter），而不是写死
            // 48 kHz——否则 44.1k 设备上 AudioTrack 会再隐式重采样一次。
            resolvedTargetRate,
        )
        if (handle == 0) {
            // 创建失败不能静默：直接抛出去，让 ExoPlayer 走它的错误路径，
            // 而不是让用户以为在听 1.0×。
            throw IllegalStateException(
                "SpeechTempo nativeCreate failed sr=$sampleRateHz ch=$channelCount"
            )
        }
        Log.i(
            TAG,
            "atempo chain ready sr=$sampleRateHz->$resolvedTargetRate " +
                "ch=$channelCount speed=$speed window=${SpeechTempo.window(handle)} " +
                "resample=${sampleRateHz != resolvedTargetRate}",
        )
    }

    fun setSpeed(value: Float) {
        if (value == speed) return
        speed = value
        if (handle != 0) {
            val rc = SpeechTempo.setTempo(handle, value.toDouble())
            if (rc != 0) Log.w(TAG, "setTempo($value) rejected rc=$rc")
        }
    }

    override fun onConfigure(
        inputAudioFormat: AudioProcessor.AudioFormat,
    ): AudioProcessor.AudioFormat {
        // 只接 16-bit PCM：ExoPlayer 交给 AudioProcessor 的就是这个格式。
        if (inputAudioFormat.encoding != C.ENCODING_PCM_16BIT) {
            throw AudioProcessor.UnhandledAudioFormatException(inputAudioFormat)
        }
        // 采样率/声道数变了就要按新参数重建算法（窗口 = sampleRate/24）。
        if (inputAudioFormat.sampleRate != sampleRateHz ||
            inputAudioFormat.channelCount != channelCount
        ) {
            sampleRateHz = inputAudioFormat.sampleRate
            channelCount = inputAudioFormat.channelCount
            if (handle != 0) {
                SpeechTempo.destroy(handle)
                handle = 0
            }
        }
        // onReset() 会销毁句柄但保留 sampleRateHz/channelCount；下一段音频只要
        // 格式相同，上面的分支就不会再建链，之后每次 nativeProcess 都返回 -1、
        // 输入被整块丢弃，表现为「一直缓冲中、没有声音」（issue #170）。
        // 句柄缺失就补建，与格式是否变化无关。
        if (handle == 0) openHandle()
        /*
         * 输出采样率 = 设备原生输出率（native 侧第一级重采样到此），必须如实
         * 报告给下游——AudioTrack 会按它初始化，报错就是变调/变速。
         */
        return AudioProcessor.AudioFormat(
            resolvedTargetRate,
            inputAudioFormat.channelCount,
            C.ENCODING_PCM_16BIT,
        )
    }

    override fun queueInput(inputBuffer: ByteBuffer) {
        inputBuffer.order(ByteOrder.nativeOrder())

        check(!inputEnded) { "SpeechTempo received input after EOS" }
        // 把新输入接到 pendingInput 后面。
        val merged = ByteBuffer.allocate(
            Math.addExact(pendingInput.remaining(), inputBuffer.remaining()),
        ).order(ByteOrder.nativeOrder())
        merged.put(pendingInput)
        merged.put(inputBuffer)
        merged.flip()
        pendingInput = merged

        drain()
    }

    /**
     * 反复把 pendingInput 喂给 native，直到 native 吃不动或者输出攒够。
     * native 侧不能保存「上一次的 src 指针」，所以每轮都必须把未消费的部分
     * 重新交进去——由 sp_atempo_process 的 src_consumed 告诉推进量。
     */
    private fun appendOutput(bytes: ByteArray, length: Int) {
        if (length == 0) return
        val out = ByteBuffer.allocate(Math.addExact(pendingOutput.remaining(), length))
            .order(ByteOrder.nativeOrder())
        out.put(pendingOutput)
        out.put(bytes, 0, length)
        out.flip()
        pendingOutput = out
    }

    private fun drain() {
        check(handle != 0 && frameBytes > 0) { "SpeechTempo is not configured" }
        while (true) {
            val available = pendingInput.remaining()
            val take = minOf(available, CHUNK_BYTES)
            val aligned = take - take % frameBytes
            val src = ByteArray(aligned)
            pendingInput.duplicate().get(src)
            val dst = ByteArray(OUTPUT_CAPACITY)
            val packed = SpeechTempo.process(handle, src, dst)
            check(packed != -1) { "SpeechTempo nativeProcess failed" }
            val produced = packed ushr 16
            val consumed = packed and 0xFFFF
            check(consumed <= src.size && produced <= dst.size &&
                consumed % frameBytes == 0 && produced % frameBytes == 0
            ) { "SpeechTempo returned invalid frame counts" }
            pendingInput.position(pendingInput.position() + consumed)
            appendOutput(dst, produced)
            if (consumed == 0 && produced == 0) {
                check(src.isEmpty()) { "SpeechTempo stalled with unconsumed PCM" }
                break
            }
            // An empty Java buffer can still leave native carry/overlap output.
        }
    }

    override fun onQueueEndOfStream() {
        if (handle != 0) {
            drain()
            check(!pendingInput.hasRemaining()) { "SpeechTempo ended with an incomplete PCM frame" }
            val dst = ByteArray(OUTPUT_CAPACITY)
            while (true) {
                val flushed = SpeechTempo.flush(handle, dst)
                check(flushed >= 0 && flushed <= dst.size && flushed % frameBytes == 0) {
                    "SpeechTempo nativeFlush failed"
                }
                if (flushed == 0) break
                appendOutput(dst, flushed)
            }
        }
        inputEnded = true
    }

    override fun getOutput(): ByteBuffer {
        val out = pendingOutput
        pendingOutput = AudioProcessor.EMPTY_BUFFER
        return out
    }

    override fun isEnded(): Boolean = inputEnded && !pendingOutput.hasRemaining()

    override fun onReset() {
        pendingInput = AudioProcessor.EMPTY_BUFFER
        pendingOutput = AudioProcessor.EMPTY_BUFFER
        inputEnded = false
        if (handle != 0) {
            SpeechTempo.destroy(handle)
            handle = 0
        }
    }

    override fun onFlush() {
        pendingInput = AudioProcessor.EMPTY_BUFFER
        pendingOutput = AudioProcessor.EMPTY_BUFFER
        inputEnded = false
        // flush 会发生在中途（seek / 换曲）：重建算法状态，保留倍速。
        if (handle != 0) {
            SpeechTempo.destroy(handle)
            handle = 0
        }
        if (sampleRateHz > 0 && channelCount > 0) openHandle()
    }
}

/**
 * `libshortplay_tempo.so` 的入口。
 *
 * 加载放在显式 [ensureLoaded] 里，不用 `init {}`：object 的 init 在**类首次
 * 被引用**时就会跑，若那时 Flutter 的 JNI 还没初始化（Dart 插件注册阶段），
 * `System.loadLibrary` 之后的 JNI 调用会直接 SIGSEGV，错误信息是
 * `JNI is not initialized ... before 'main()'`。真机上报过这个崩溃。
 *
 * 真正需要 native 的时机是 AudioProcessor 的 configure，那时引擎已就绪。
 */
internal object SpeechTempo {
    @Volatile
    private var loaded = false

    private fun ensureLoaded() {
        if (loaded) return
        synchronized(this) {
            if (loaded) return
            System.loadLibrary("shortplay_tempo")
            loaded = true
        }
    }

    fun createChain(
        sampleRate: Int,
        channels: Int,
        tempo: Double,
        targetRate: Int,
    ): Int {
        ensureLoaded()
        return nativeCreateChain(sampleRate, channels, tempo, targetRate)
    }

    fun destroy(handle: Int) {
        ensureLoaded()
        nativeDestroy(handle)
    }

    fun setTempo(handle: Int, tempo: Double): Int {
        ensureLoaded()
        return nativeSetTempo(handle, tempo)
    }

    fun window(handle: Int): Int {
        ensureLoaded()
        return nativeWindow(handle)
    }

    fun process(handle: Int, src: ByteArray, dst: ByteArray): Int {
        ensureLoaded()
        return nativeProcess(handle, src, dst)
    }

    fun flush(handle: Int, dst: ByteArray): Int {
        ensureLoaded()
        return nativeFlush(handle, dst)
    }

    private external fun nativeCreateChain(
        sampleRate: Int,
        channels: Int,
        tempo: Double,
        targetRate: Int,
    ): Int

    external fun nativeDestroy(handle: Int)
    external fun nativeSetTempo(handle: Int, tempo: Double): Int
    external fun nativeWindow(handle: Int): Int
    external fun nativeProcess(handle: Int, src: ByteArray, dst: ByteArray): Int
    external fun nativeFlush(handle: Int, dst: ByteArray): Int
}
