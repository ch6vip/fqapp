package com.fqapp.fqapp

import android.util.Log
import androidx.annotation.OptIn
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.util.UnstableApi
import androidx.media3.common.util.Util
import androidx.media3.exoplayer.audio.DefaultAudioSink
import androidx.media3.exoplayer.audio.SilenceSkippingAudioProcessor

/**
 * 把 Media3 默认链路里的 Sonic 时伸缩换成移植自 FFmpeg `af_atempo` 的 WSOLA
 * （issue #129，听感对齐番茄官方）。
 *
 * 为什么不是直接 `setAudioProcessors(...)`：`DefaultAudioSink` 只从
 * [DefaultAudioSink.AudioProcessorChain] 拿处理器，而默认实现的
 * `applyPlaybackParameters` 会把速度写进 `SonicAudioProcessor`。要换掉变速
 * 实现，就必须自己实现这个链。
 *
 * 编排保持与 Media3 默认一致（`DefaultAudioSink.DefaultAudioProcessorChain`）：
 *
 *   `自定义 WSOLA` -> `SilenceSkipping` -> `应用方处理器…` -> `ToInt16Pcm`
 *
 * 这条链用行内代码写：KDoc 会把中括号当链接解析，带省略号的中括号直接
 * 报 `Closing bracket expected`。
 *
 * 速度只在 [applyPlaybackParameters] 里下发；音高固定 1.0，与官方
 * `PlaybackParams().setPitch(1.0f)` 一致（只变速不变调）。
 */
@OptIn(UnstableApi::class)
internal class WsolaProcessorChain(private val tempoProcessor: SpeechTempoProcessor) : DefaultAudioSink.AudioProcessorChain {

    /**
     * 按设备原生输出采样率建链。
     *
     * [nativeOutputSampleRate] 对应官方的 `AudioTrack.getNativeOutputSampleRate()`：
     * TTPlayer 在 atempo 之前用 samplefilter 把 PCM 统一到这个速率，避免
     * AudioTrack 再做一次隐式重采样。这里由 Media3 的 `AudioCapabilities`
     * 提供同一个值。
     */
    constructor(nativeOutputSampleRate: Int) : this(
        SpeechTempoProcessor(targetSampleRate = nativeOutputSampleRate)
    )

    private val silenceSkipping = SilenceSkippingAudioProcessor()
    private val toInt16Pcm = ToInt16PcmAudioProcessor()
    private val appProcessors = arrayOf<AudioProcessor>()

    private var skipSilenceEnabled = false

    /**
     * 最近一次下发的倍速。
     *
     * [getMediaDuration] 要拿它把播放时长换算回媒体时长，所以必须在这里留一份：
     * Media3 调那个函数时不带任何速度参数。
     */
    private var speed = 1f

    private val processors: Array<AudioProcessor> = buildList {
        add(tempoProcessor)
        add(silenceSkipping)
        addAll(appProcessors)
        add(toInt16Pcm)
    }.toTypedArray()

    override fun getAudioProcessors(): Array<AudioProcessor> = processors

    override fun applyPlaybackParameters(playbackParameters: PlaybackParameters): PlaybackParameters {
        // 音高恒为 1.0：只做时伸缩，与官方 PlaybackParams.setPitch(1.0f) 对齐。
        tempoProcessor.setSpeed(playbackParameters.speed)
        // 记住倍速：下面 getMediaDuration 要把播放时长乘回它。
        speed = playbackParameters.speed
        return PlaybackParameters(playbackParameters.speed)
    }

    override fun applySkipSilenceEnabled(skipSilenceEnabled: Boolean): Boolean {
        this.skipSilenceEnabled = skipSilenceEnabled
        silenceSkipping.setEnabled(skipSilenceEnabled)
        return skipSilenceEnabled
    }

    /**
     * 播放时长 -> 媒体时长，**必须乘倍速**。
     *
     * `DefaultAudioSink.applyMediaPositionParameters` 拿 AudioTrack 的播放时长调
     * 这个函数，算出来的值就是 `player.currentPosition`（默认链里这个方法转发给
     * `sonicAudioProcessor.getMediaDuration`，同样不是恒等）。WSOLA 的产出是
     * 「输入 / tempo」：1.5× 时 AudioTrack 走完 1 秒，媒体已经过去 1.5 秒。
     *
     * 曾经这里恒等返回、并注释「Media3 只用它做 seek 提示」，那个判断是错的。恒等
     * 的后果是上报位置只有真实进度的 `1/tempo`：1.5× 下听完 10 分钟的内容，位置只
     * 报到 6 分 40 秒（少 3 分 20 秒），且误差随播放时长线性累积——正文高亮越听越
     * 落后、保存的进度跟着偏小、媒体卡片的进度条也走不满。
     */
    override fun getMediaDuration(playoutDurationUs: Long): Long {
        if (playoutDurationUs <= 0L) return 0L
        val current = speed
        // 速度非法时退回恒等：宁可位置不准，也不能让整条播放链崩掉。
        if (!current.isFinite() || current <= 0f || current == 1f) return playoutDurationUs
        return Util.getMediaDurationForPlayoutDuration(playoutDurationUs, current)
    }

    override fun getSkippedOutputFrameCount(): Long = if (skipSilenceEnabled) silenceSkipping.skippedFrames else 0L
}

/**
 * 保证最终交给 AudioTrack 的是 16-bit PCM。
 *
 * 与 Media3 默认链里的 `ToInt16PcmAudioProcessor` 等价——`DefaultAudioSink`
 * 在没有自定义链时自己补这一步，走自定义链就必须显式带上。
 */
@OptIn(UnstableApi::class)
internal class ToInt16PcmAudioProcessor : androidx.media3.common.audio.BaseAudioProcessor() {
    private var outputBuffer: java.nio.ByteBuffer = AudioProcessor.EMPTY_BUFFER
    private var inputEnded = false
    private var pendingInput: java.nio.ByteBuffer = AudioProcessor.EMPTY_BUFFER

    override fun onConfigure(inputAudioFormat: AudioProcessor.AudioFormat): AudioProcessor.AudioFormat = when (inputAudioFormat.encoding) {
        androidx.media3.common.C.ENCODING_PCM_16BIT,
        androidx.media3.common.C.ENCODING_PCM_FLOAT,
        androidx.media3.common.C.ENCODING_PCM_24BIT,
        androidx.media3.common.C.ENCODING_PCM_32BIT ->
            AudioProcessor.AudioFormat(
                inputAudioFormat.sampleRate,
                inputAudioFormat.channelCount,
                androidx.media3.common.C.ENCODING_PCM_16BIT
            )

        else -> throw AudioProcessor.UnhandledAudioFormatException(inputAudioFormat)
    }

    override fun queueInput(inputBuffer: java.nio.ByteBuffer) {
        // WSOLA 只吃 16-bit，上游已经是 16-bit，这里直接透传。
        val out = java.nio.ByteBuffer.allocate(
            pendingInput.remaining() + inputBuffer.remaining()
        )
        out.put(pendingInput)
        out.put(inputBuffer)
        out.flip()
        pendingInput = out
        outputBuffer = pendingInput
        pendingInput = AudioProcessor.EMPTY_BUFFER
    }

    override fun onQueueEndOfStream() {
        inputEnded = true
    }

    override fun getOutput(): java.nio.ByteBuffer {
        val out = outputBuffer
        outputBuffer = AudioProcessor.EMPTY_BUFFER
        return out
    }

    override fun isEnded(): Boolean = inputEnded && !outputBuffer.hasRemaining()

    override fun onReset() {
        outputBuffer = AudioProcessor.EMPTY_BUFFER
        pendingInput = AudioProcessor.EMPTY_BUFFER
        inputEnded = false
    }

    override fun onFlush() = onReset()
}
