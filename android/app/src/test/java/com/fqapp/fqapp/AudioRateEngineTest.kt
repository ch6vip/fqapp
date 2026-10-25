package com.fqapp.fqapp

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * issue #129：听书倍速改用系统混音器时伸缩（AudioTrack/APM），修复高倍速下的
 * 电音/金属感。这里只测纯逻辑：名字解析，以及「只有纯音频播放器才允许系统
 * 变速」这条边界——视频必须留在 Media3 内建变速，否则音画不再同步计时。
 */
class AudioRateEngineTest {
    @Test fun `missing or unknown names fall back to the platform engine`() {
        assertEquals(AudioRateEngine.WSOLA, AudioRateEngine.fromName(null))
        assertEquals(AudioRateEngine.WSOLA, AudioRateEngine.fromName(""))
        assertEquals(AudioRateEngine.WSOLA, AudioRateEngine.fromName("sonic2"))
    }

    @Test fun `known names are parsed case insensitively`() {
        assertEquals(AudioRateEngine.PLATFORM, AudioRateEngine.fromName("platform"))
        assertEquals(AudioRateEngine.PLATFORM, AudioRateEngine.fromName("PLATFORM"))
        assertEquals(AudioRateEngine.BUILT_IN, AudioRateEngine.fromName("builtIn"))
    }

    @Test fun `dart and kotlin enum names stay in sync`() {
        // Dart 侧用 `name` 序列化（builtIn，不是 BUILT_IN），两边靠 wireName
        // 逐字对齐，否则设置静默失效。
        assertEquals(
            listOf("wsola", "platform", "builtIn"),
            AudioRateEngine.entries.map { it.wireName },
        )
        // 解码器偏好两边都用 `name.lowercase()`。
        assertEquals(
            listOf("automatic", "hardware", "software"),
            VideoDecoderPreference.entries.map { it.name.lowercase() },
        )
    }

    @Test fun `audio players honour the selected engine`() {
        val wsola = PlayerBuildOptions(audioOnly = true, rateEngine = AudioRateEngine.WSOLA)
        assertEquals(AudioRateEngine.WSOLA, wsola.effectiveRateEngine)

        val platform = PlayerBuildOptions(audioOnly = true, rateEngine = AudioRateEngine.PLATFORM)
        assertEquals(AudioRateEngine.PLATFORM, platform.effectiveRateEngine)

        val compat = PlayerBuildOptions(audioOnly = true, rateEngine = AudioRateEngine.BUILT_IN)
        assertEquals(AudioRateEngine.BUILT_IN, compat.effectiveRateEngine)
    }

    @Test fun `video players always time stretch in house`() {
        // 视频播放器即使传了 PLATFORM 也必须退回内建变速。
        val video = PlayerBuildOptions(
            decoder = VideoDecoderPreference.AUTOMATIC,
            audioOnly = false,
            rateEngine = AudioRateEngine.PLATFORM,
        )
        assertEquals(AudioRateEngine.BUILT_IN, video.effectiveRateEngine)
    }
}
