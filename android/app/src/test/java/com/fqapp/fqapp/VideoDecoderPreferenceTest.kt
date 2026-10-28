package com.fqapp.fqapp

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * issue #92: 联发科部分芯片在 Android 15 上播 HEVC + 加密内容时硬解静默
 * 黑屏（androidx/media#2711），只能靠用户手动切软解绕开。这里只测纯逻辑：
 * 名字解析与选择器的过滤/排序规则，不依赖设备上的真实解码器列表。
 */
class VideoDecoderPreferenceTest {
    @Test fun `unknown or missing names fall back to automatic`() {
        assertEquals(VideoDecoderPreference.AUTOMATIC, VideoDecoderPreference.fromName(null))
        assertEquals(VideoDecoderPreference.AUTOMATIC, VideoDecoderPreference.fromName(""))
        assertEquals(VideoDecoderPreference.AUTOMATIC, VideoDecoderPreference.fromName("turbo"))
    }

    @Test fun `known names are parsed case insensitively`() {
        assertEquals(VideoDecoderPreference.SOFTWARE, VideoDecoderPreference.fromName("software"))
        assertEquals(VideoDecoderPreference.SOFTWARE, VideoDecoderPreference.fromName("SOFTWARE"))
        assertEquals(VideoDecoderPreference.HARDWARE, VideoDecoderPreference.fromName("hardware"))
        assertEquals(VideoDecoderPreference.AUTOMATIC, VideoDecoderPreference.fromName("automatic"))
    }

    @Test fun `dart and kotlin enum names stay in sync`() {
        // Dart 侧用 `name` 序列化，两个枚举必须逐字对齐，否则设置静默失效。
        assertEquals(
            listOf("automatic", "hardware", "software"),
            VideoDecoderPreference.entries.map { it.name.lowercase() }
        )
    }

    @Test fun `software decoding only keeps aosp decoders`() {
        val all = listOf(
            "OMX.MTK.VIDEO.DECODER.AVC",
            "OMX.google.h264.decoder",
            "c2.qti.hevc.decoder",
            "c2.android.hevc.decoder"
        )
        val software = all.filter { isSoftwareDecoder(it) }
        assertEquals(listOf("OMX.google.h264.decoder", "c2.android.hevc.decoder"), software)
    }

    @Test fun `hardware first keeps every candidate`() {
        val all = listOf(
            "OMX.google.h264.decoder",
            "OMX.MTK.VIDEO.DECODER.AVC"
        )
        // 硬解优先只是排序：硬解不可用时仍要能回落到软解，不能删候选。
        val ordered = all.filterNot { isSoftwareDecoder(it) } + all.filter { isSoftwareDecoder(it) }
        assertEquals(listOf("OMX.MTK.VIDEO.DECODER.AVC", "OMX.google.h264.decoder"), ordered)
    }
}
