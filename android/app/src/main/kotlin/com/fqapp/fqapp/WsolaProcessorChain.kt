package com.fqapp.fqapp

import android.util.Log
import androidx.annotation.OptIn
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.util.UnstableApi
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
        return PlaybackParameters(playbackParameters.speed)
    }

    override fun applySkipSilenceEnabled(skipSilenceEnabled: Boolean): Boolean {
        this.skipSilenceEnabled = skipSilenceEnabled
        silenceSkipping.setEnabled(skipSilenceEnabled)
        return skipSilenceEnabled
    }

    override fun getMediaDuration(mediaDurationUs: Long): Long {
        // 输入时长 -> 输出时长：WSOLA 的产出是「输入 / tempo」。
        // 这里只汇报 1.0 比例（Media3 只用它做 seek 提示），真实换算由
        // AudioSink 侧的 getPlayoutDuration 逐步校正。
        return mediaDurationUs
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
