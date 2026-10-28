package com.fqapp.fqapp

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SoftwareDecoderTest {
    @Test fun aospSoftwareDecodersAreDetected() {
        assertTrue(isSoftwareDecoder("OMX.google.h264.decoder"))
        assertTrue(isSoftwareDecoder("OMX.google.hevc.decoder"))
        assertTrue(isSoftwareDecoder("OMX.google.vp9.decoder"))
        assertTrue(isSoftwareDecoder("c2.android.avc.decoder"))
        assertTrue(isSoftwareDecoder("c2.android.hevc.decoder"))
    }

    @Test fun hardwareDecodersAreNotTreatedAsSoftware() {
        assertFalse(isSoftwareDecoder("OMX.qcom.video.decoder.avc"))
        assertFalse(isSoftwareDecoder("OMX.Exynos.avc.dec"))
        assertFalse(isSoftwareDecoder("OMX.MTK.VIDEO.DECODER.AVC"))
        assertFalse(isSoftwareDecoder("c2.qti.avc.decoder"))
        assertFalse(isSoftwareDecoder("OMX.hisi.video.decoder.avc"))
        assertFalse(isSoftwareDecoder(""))
    }
}
