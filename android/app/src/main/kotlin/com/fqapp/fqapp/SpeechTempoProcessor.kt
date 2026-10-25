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
) : BaseAudioProcessor() {

    /** 真实采样率要到 configure 才知道（WSOLA 的窗口由它决定）。 */
    private var sampleRateHz: Int = 0
    private var channelCount: Int = 0

    private companion object {
        const val TAG = "SpeechTempoProcessor"

        /** 交给 native 的单块上限：够覆盖多个 WSOLA 窗口，又不至于延迟过大。 */
        const val CHUNK_BYTES = 32 * 1024

        /** 输出缓冲上限：比例最高 0.5×（放大两倍）再留些余量。 */
        const val OUTPUT_CAPACITY = CHUNK_BYTES * 3
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
        handle = SpeechTempo.nativeCreate(sampleRateHz, channelCount, speed.toDouble())
        if (handle == 0) {
            // 创建失败不能静默：直接抛出去，让 ExoPlayer 走它的错误路径，
            // 而不是让用户以为在听 1.0×。
            throw IllegalStateException(
                "SpeechTempo nativeCreate failed sr=$sampleRateHz ch=$channelCount"
            )
        }
        Log.i(
            TAG,
            "atempo ready sr=$sampleRateHz ch=$channelCount speed=$speed " +
                "window=${SpeechTempo.nativeWindow(handle)}",
        )
    }

    fun setSpeed(value: Float) {
        if (value == speed) return
        speed = value
        if (handle != 0) {
            val rc = SpeechTempo.nativeSetTempo(handle, value.toDouble())
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
                SpeechTempo.nativeDestroy(handle)
                handle = 0
            }
            openHandle()
        }
        return inputAudioFormat
    }

    override fun queueInput(inputBuffer: ByteBuffer) {
        inputBuffer.order(ByteOrder.nativeOrder())

        // 把新输入接到 pendingInput 后面。
        val merged = ByteBuffer.allocate(
            pendingInput.remaining() + inputBuffer.remaining(),
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
    private fun drain() {
        while (pendingInput.remaining() >= frameBytes) {
            val take = minOf(pendingInput.remaining(), CHUNK_BYTES)
            // 保证是完整帧的整数倍。
            val takeAligned = take - (take % frameBytes)
            if (takeAligned <= 0) break

            val src = ByteArray(takeAligned)
            pendingInput.get(src)

            val dst = ByteArray(OUTPUT_CAPACITY)
            val packed = SpeechTempo.nativeProcess(handle, src, dst)
            if (packed < 0) {
                Log.e(TAG, "nativeProcess failed, dropping round")
                break
            }
            // 高 16 位 = 产出字节数，低 16 位 = 消费掉的输入字节数（见 JNI 注释）。
            val produced = packed ushr 16
            val consumed = packed and 0xFFFF

            // 没吃完的部分必须放回队首——哪怕一个字节都没吃（native 需要攒够
            // 一个 WSOLA 窗口才出帧）。丢掉它等于丢音频样本。
            if (consumed < takeAligned) {
                val rest = takeAligned - consumed
                val rebuild = ByteBuffer.allocate(rest + pendingInput.remaining())
                    .order(ByteOrder.nativeOrder())
                rebuild.put(src, consumed, rest)
                rebuild.put(pendingInput)
                rebuild.flip()
                pendingInput = rebuild
            }

            if (produced > 0) {
                val out = ByteBuffer.allocate(pendingOutput.remaining() + produced)
                    .order(ByteOrder.nativeOrder())
                out.put(pendingOutput)
                out.put(dst, 0, produced)
                out.flip()
                pendingOutput = out
            }

            // 一点都没推进：再喂同样的数据也不会变，等更多输入进来。
            if (consumed == 0) break
        }
    }

    override fun onQueueEndOfStream() {
        if (handle != 0) {
            // 先把攒着的输入喂完。
            drain()
            val dst = ByteArray(OUTPUT_CAPACITY)
            var guard = 0
            while (guard++ < 64) {
                val flushed = SpeechTempo.nativeFlush(handle, dst)
                if (flushed <= 0) break
                val out = ByteBuffer.allocate(pendingOutput.remaining() + flushed)
                    .order(ByteOrder.nativeOrder())
                out.put(pendingOutput)
                out.put(dst, 0, flushed)
                out.flip()
                pendingOutput = out
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
            SpeechTempo.nativeDestroy(handle)
            handle = 0
        }
    }

    override fun onFlush() {
        pendingInput = AudioProcessor.EMPTY_BUFFER
        pendingOutput = AudioProcessor.EMPTY_BUFFER
        inputEnded = false
        // flush 会发生在中途（seek / 换曲）：重建算法状态，保留倍速。
        if (handle != 0) {
            SpeechTempo.nativeDestroy(handle)
            handle = 0
        }
        if (sampleRateHz > 0 && channelCount > 0) openHandle()
    }
}

/** `libshortplay_tempo.so` 的入口。 */
internal object SpeechTempo {
    init {
        System.loadLibrary("shortplay_tempo")
    }

    external fun nativeCreate(sampleRate: Int, channels: Int, tempo: Double): Int
    external fun nativeDestroy(handle: Int)
    external fun nativeSetTempo(handle: Int, tempo: Double): Int
    external fun nativeWindow(handle: Int): Int
    external fun nativeProcess(handle: Int, src: ByteArray, dst: ByteArray): Int
    external fun nativeFlush(handle: Int, dst: ByteArray): Int
}
