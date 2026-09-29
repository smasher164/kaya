package dev.kaya

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * THE SYNTHESIZED PICKER'S ARITHMETIC (docs/color-picker-plan.md §6): no leg
 * moves a slider or types into the sheet's hex field, since set_color drives
 * the draft through its value, so a wrong HSV conversion or hex reading
 * passes every scene.
 */
class KayaColorPickerTest {

    @Test
    fun everyByteSurvivesHsvAndBack() {
        for (r in 0..255 step 5) for (g in 0..255 step 3) for (b in 0..255 step 7) {
            val hsv = kayaRgbToHsv(r / 255.0, g / 255.0, b / 255.0)
            val rgb = kayaHsvToRgb(hsv[0], hsv[1], hsv[2])
            assertArrayEquals("$r $g $b", doubleArrayOf(r / 255.0, g / 255.0, b / 255.0), rgb, 1e-9)
        }
    }

    @Test
    fun theHueSectorsLandOnTheirPrimaries() {
        assertArrayEquals(doubleArrayOf(1.0, 0.0, 0.0), kayaHsvToRgb(0.0, 1.0, 1.0), 1e-12)
        assertArrayEquals(doubleArrayOf(1.0, 1.0, 0.0), kayaHsvToRgb(60.0, 1.0, 1.0), 1e-12)
        assertArrayEquals(doubleArrayOf(0.0, 1.0, 0.0), kayaHsvToRgb(120.0, 1.0, 1.0), 1e-12)
        assertArrayEquals(doubleArrayOf(0.0, 0.0, 1.0), kayaHsvToRgb(240.0, 1.0, 1.0), 1e-12)
        assertArrayEquals(doubleArrayOf(1.0, 0.0, 0.0), kayaHsvToRgb(360.0, 1.0, 1.0), 1e-12)
        assertArrayEquals(doubleArrayOf(0.5, 0.5, 0.5), kayaHsvToRgb(200.0, 0.0, 0.5), 1e-12)
        assertArrayEquals(doubleArrayOf(300.0, 1.0, 1.0), kayaRgbToHsv(1.0, 0.0, 1.0), 1e-12)
    }

    @Test
    fun theHexFieldReadsSixDigitsAndEightOnlyWithAlpha() {
        assertEquals(0x3584E4FFL, kayaParseColorHex("3584E4", alpha = false))
        assertEquals(0x3584E4FFL, kayaParseColorHex(" #3584e4 ", alpha = true))
        assertEquals(0xE01B2480L, kayaParseColorHex("E01B2480", alpha = true))
        assertNull(kayaParseColorHex("E01B2480", alpha = false))
        for (bad in listOf("", "#", "3584E", "3584E4F", "GG84E4", "+3584E4", "3584E4FF0")) {
            assertNull(bad, kayaParseColorHex(bad, alpha = true))
        }
        assertEquals("E01B2480", kayaDraftHex(0xE01B2480L, alpha = true))
        assertEquals("E01B24", kayaDraftHex(0xE01B2480L, alpha = false))
    }

    @Test
    fun anOpaqueDraftHoldsATranslucentChoiceOpaque() {
        val opaque = KayaColorDraft(0x336699FFL, alpha = false)
        opaque.take(0x26A26980L)
        assertEquals(1.0, opaque.components()[3], 0.0)
        assertEquals("26A269", opaque.hex)
        val glaze = KayaColorDraft(0x26A269FFL, alpha = true)
        glaze.take(0xE01B2480L)
        assertEquals(0x80 / 255.0, glaze.components()[3], 1e-12)
        glaze.typed("3584E4")
        assertEquals("3584E4", glaze.hex)
        assertEquals(1.0, glaze.components()[3], 0.0)
        glaze.typed("3584")
        assertEquals(false, glaze.hexValid)
        assertEquals(0x35 / 255.0, glaze.components()[0], 1e-9)
    }
}
