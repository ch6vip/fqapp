package com.fqapp.fqapp

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RendererCompatibilityTest {
    @Test fun mt6895HardwareMatches() {
        assertTrue(RendererCompatibility.isAffectedDevice("mt6895", "", ""))
        assertTrue(RendererCompatibility.isAffectedDevice("MT6895", "", ""))
        assertTrue(RendererCompatibility.isAffectedDevice("", "mt6895", ""))
        assertTrue(RendererCompatibility.isAffectedDevice("", "", "MT6895"))
    }

    @Test fun mt6895WithLetterSuffixMatches() {
        // Existing rule: a trailing letter run (e.g. a revision suffix) still matches.
        assertTrue(RendererCompatibility.isAffectedDevice("mt6895z", "", ""))
    }

    @Test fun mt6895WithDigitSuffixDoesNotMatch() {
        assertFalse(RendererCompatibility.isAffectedDevice("mt68952", "", ""))
        assertFalse(RendererCompatibility.isAffectedDevice("mt6893", "", ""))
    }

    @Test fun dimensity8100MatchesInAllNameForms() {
        assertTrue(RendererCompatibility.isAffectedDevice("Dimensity 8100", "", ""))
        assertTrue(RendererCompatibility.isAffectedDevice("dimensity8100", "", ""))
        assertTrue(RendererCompatibility.isAffectedDevice("MediaTek Dimensity 8100", "", ""))
        assertTrue(RendererCompatibility.isAffectedDevice("Dimensity 8100-Max", "", ""))
        assertTrue(RendererCompatibility.isAffectedDevice("Dimensity 8100 Ultra", "", ""))
        assertTrue(RendererCompatibility.isAffectedDevice("MediaTek Dimensity 8100 Ultra", "", ""))
    }

    @Test fun otherDimensityChipsDoNotMatch() {
        assertFalse(RendererCompatibility.isAffectedDevice("Dimensity 8200", "", ""))
        assertFalse(RendererCompatibility.isAffectedDevice("Dimensity 810", "", ""))
        assertFalse(RendererCompatibility.isAffectedDevice("Dimensity 81000", "", ""))
    }

    @Test fun unrelatedHardwareDoesNotMatch() {
        assertFalse(RendererCompatibility.isAffectedDevice("SM8650", "pineapple", ""))
        assertFalse(RendererCompatibility.isAffectedDevice("MT6983", "", "Dimensity 9200"))
        assertFalse(RendererCompatibility.isAffectedDevice("", "", ""))
    }

    @Test fun anySingleFieldMatchingIsEnough() {
        assertTrue(RendererCompatibility.isAffectedDevice("other", "other", "mt6895"))
        assertFalse(RendererCompatibility.isAffectedDevice("other", "other", "other"))
    }

    @Test fun normalizeStripsCaseAndPunctuation() {
        assertEquals("dimensity8100ultra", RendererCompatibility.normalizeDeviceId("Dimensity 8100 Ultra"))
        assertEquals("mt6895", RendererCompatibility.normalizeDeviceId(" MT-6895 "))
        assertEquals("", RendererCompatibility.normalizeDeviceId("---"))
    }
}
