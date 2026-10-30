package com.fqapp.fqapp

import androidx.media3.common.PlaybackParameters
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * 倍速下「位置越听越偏」的回归测试。
 *
 * 症状：1.5× 听书时正文高亮逐渐落后于实际朗读，偏差随播放时长线性增长；
 * 1.0× 与系统朗读（TTS）都正常。
 *
 * 根因：`WsolaProcessorChain.getMediaDuration` 曾经恒等返回。Media3 的
 * `DefaultAudioSink.applyMediaPositionParameters` 正是拿 AudioTrack 的播放时长
 * 调这个函数来算 `player.currentPosition`，恒等等于把播放时长当成了媒体时长，
 * 而 WSOLA 的产出是「输入 / tempo」，两者差一个倍速。
 *
 * 这里直接对着链对象验算，不需要 WSOLA 的 native 库（构造与下发倍速都不碰
 * native，只有 configure 之后才会）。
 */
class WsolaPositionTest {
    private val oneSecond = 1_000_000L

    /** 按给定倍速建一条链，等价于播放器正常的那一步下发。 */
    private fun chainAt(speed: Float): WsolaProcessorChain =
        WsolaProcessorChain(48000).apply {
            applyPlaybackParameters(PlaybackParameters(speed))
        }

    private fun mediaUs(playoutUs: Long, speed: Float): Long =
        chainAt(speed).getMediaDuration(playoutUs)

    @Test fun `at 1x playout and media time are identical`() {
        assertEquals(oneSecond, mediaUs(oneSecond, 1f))
        assertEquals(600 * oneSecond, mediaUs(600 * oneSecond, 1f))
    }

    @Test fun `faster playback must report a longer media position`() {
        // 1.5× 播了 1 秒播放时长，媒体已经过去 1.5 秒。
        assertEquals(1_500_000L, mediaUs(oneSecond, 1.5f))
        assertEquals(2 * oneSecond, mediaUs(oneSecond, 2f))
        assertEquals(1_250_000L, mediaUs(oneSecond, 1.25f))
    }

    @Test fun `slower playback must report a shorter media position`() {
        assertEquals(750_000L, mediaUs(oneSecond, 0.75f))
        assertEquals(500_000L, mediaUs(oneSecond, 0.5f))
    }

    @Test fun `the old identity behaviour is off by exactly one speed factor`() {
        // 回归的核心断言：1.5× 听完 10 分钟播放时长，真实媒体位置是 15 分钟。
        // 恒等实现只会报 10 分钟 —— 差 5 分钟，而且这个差值随时长线性增长。
        val playout = 600 * oneSecond
        val media = mediaUs(playout, 1.5f)
        assertEquals(900 * oneSecond, media)
        assertEquals(300 * oneSecond, media - playout)
        // 位置越大偏差越大，正是用户描述的「越听越偏」。
        assertEquals(
            2 * (media - playout),
            mediaUs(playout * 2, 1.5f) - playout * 2,
        )
    }

    @Test fun `non-positive playout duration reports zero`() {
        // 起播瞬间 / 异常上报可能给 0 或负数，此时位置只能是 0。
        assertEquals(0L, mediaUs(0L, 1.5f))
        assertEquals(0L, mediaUs(-oneSecond, 1.5f))
        assertEquals(0L, mediaUs(0L, 1f))
    }

    // 倍速本身不必测非法值：`PlaybackParameters` 的构造函数会先拒掉 speed <= 0
    // 或非有限值（IllegalArgumentException），链上拿到的永远是合法速度。
    // getMediaDuration 里那道兜底因此是无害的死分支，留着防将来有人绕过
    // PlaybackParameters 直接改速度。
}
