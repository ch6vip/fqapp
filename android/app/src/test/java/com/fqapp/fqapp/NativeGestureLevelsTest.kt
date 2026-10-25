package com.fqapp.fqapp

import org.junit.Assert.assertEquals
import org.junit.Test

/** 分屏手势档位换算的 JVM 单测（不依赖 Android 运行时）。 */
class NativeGestureLevelsTest {
    @Test
    fun brightnessUsesStandardEightBitScale() {
        assertEquals(0.02f, NativeGestureLevels.normaliseBrightness(0), 0.0001f)
        assertEquals(128f / 255f, NativeGestureLevels.normaliseBrightness(128), 0.0001f)
        assertEquals(1f, NativeGestureLevels.normaliseBrightness(255), 0.0001f)
    }

    @Test
    fun brightnessDetectsTwelveBitRomScale() {
        // ColorOS / 12bit 面板：满值 4095。按 255 归一化会读成 1600%，
        // 夹完后亮度起点永远是 100%。
        assertEquals(0.5f, NativeGestureLevels.normaliseBrightness(2048), 0.001f)
        assertEquals(1f, NativeGestureLevels.normaliseBrightness(4095), 0.0001f)
        assertEquals(1f, NativeGestureLevels.normaliseBrightness(99999), 0.0001f)
    }

    @Test
    fun brightnessNeverFallsBelowTheScreenOffFloor() {
        assertEquals(0.02f, NativeGestureLevels.normaliseBrightness(-5), 0.0001f)
    }

    @Test
    fun volumeFractionClampsToTheDeviceStepCount() {
        assertEquals(0.5, NativeGestureLevels.volumeFraction(80, 160), 0.0001)
        assertEquals(1.0, NativeGestureLevels.volumeFraction(200, 160), 0.0001)
        assertEquals(0.0, NativeGestureLevels.volumeFraction(-3, 160), 0.0001)
        assertEquals(0.0, NativeGestureLevels.volumeFraction(3, 0), 0.0001)
    }

    @Test
    fun volumeIndexRoundsToTheSameStepTheSystemPanelShows() {
        assertEquals(80, NativeGestureLevels.volumeIndex(0.5f, 160))
        assertEquals(160, NativeGestureLevels.volumeIndex(1.2f, 160))
        assertEquals(0, NativeGestureLevels.volumeIndex(-0.2f, 160))
        assertEquals(0, NativeGestureLevels.volumeIndex(0.5f, 0))
    }
}
