package dev.kaya

import androidx.compose.material3.ColorScheme
import androidx.compose.ui.graphics.Color
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The scheme-derivation wall (docs/deferred.md's M3 entry): a branded
 * scheme follows its seed everywhere Material's derivation would, and
 * NEVER on the error family. Runs on the host JVM through
 * check-compose, so the emulator never proves the brand scheme first.
 */
class KayaColorSchemesTest {

    // The portfolio's own seed — the mark's blue.
    private val seed = 0x1C71D8

    private fun Color.argb(): Int {
        val c = this.convert(androidx.compose.ui.graphics.colorspace.ColorSpaces.Srgb)
        val r = (c.red * 255f + 0.5f).toInt().coerceIn(0, 255)
        val g = (c.green * 255f + 0.5f).toInt().coerceIn(0, 255)
        val b = (c.blue * 255f + 0.5f).toInt().coerceIn(0, 255)
        return (0xFF shl 24) or (r shl 16) or (g shl 8) or b
    }

    /** RGB hue in degrees, or null for a near-grey where hue is noise. */
    private fun hueOf(color: Color): Float? {
        val argb = color.argb()
        val r = ((argb shr 16) and 0xFF) / 255f
        val g = ((argb shr 8) and 0xFF) / 255f
        val b = (argb and 0xFF) / 255f
        val max = maxOf(r, g, b)
        val min = minOf(r, g, b)
        val d = max - min
        if (d < 0.02f) return null
        val h = when (max) {
            r -> 60f * (((g - b) / d) % 6f)
            g -> 60f * (((b - r) / d) + 2f)
            else -> 60f * (((r - g) / d) + 4f)
        }
        return if (h < 0f) h + 360f else h
    }

    private fun hueDistance(a: Float, b: Float): Float {
        val d = kotlin.math.abs(a - b) % 360f
        return if (d > 180f) 360f - d else d
    }

    private val seedHue = hueOf(Color(0xFF000000.toInt() or seed))!!

    /** The blue seed's hint: on a tinted near-grey the blue channel
     * leads the red one, which RGB hue on a near-grey does not. */
    private fun assertCoolHint(name: String, color: Color) {
        val argb = color.argb()
        val r = (argb shr 16) and 0xFF
        val b = argb and 0xFF
        assertTrue("$name carries no hint of the blue seed (r=$r b=$b)", b > r)
    }

    private fun branded(dark: Boolean, contrast: Float = 0f): ColorScheme =
        KayaColorSchemes.of(seed, dark, contrast)

    private fun baseline(dark: Boolean): ColorScheme =
        KayaColorSchemes.of(null, dark, 0f)

    @Test
    fun secondaryFamilyFollowsTheSeed() {
        for (dark in listOf(false, true)) {
            val s = branded(dark)
            val base = baseline(dark)
            assertNotEquals(
                "secondaryContainer (dark=$dark) is still Material baseline",
                base.secondaryContainer.argb(), s.secondaryContainer.argb(),
            )
            val hue = hueOf(s.secondaryContainer)
            if (hue != null) {
                assertTrue(
                    "secondaryContainer hue $hue is not near the seed's $seedHue (dark=$dark)",
                    hueDistance(hue, seedHue) < 45f,
                )
            } else {
                assertCoolHint("secondaryContainer (dark=$dark)", s.secondaryContainer)
            }
        }
    }

    @Test
    fun tertiaryRotatesSixtyDegreesFromTheSeed() {
        for (dark in listOf(false, true)) {
            val s = branded(dark)
            val base = baseline(dark)
            assertNotEquals(
                "tertiaryContainer (dark=$dark) is still Material baseline",
                base.tertiaryContainer.argb(), s.tertiaryContainer.argb(),
            )
            val hue = hueOf(s.tertiaryContainer)
            if (hue != null) {
                // HCT hue and RGB hue diverge, so the band is generous:
                // the rotated palette must sit AWAY from the seed, on
                // the +60 side, not on it.
                assertTrue(
                    "tertiaryContainer hue $hue sits on the seed's own hue (dark=$dark)",
                    hueDistance(hue, seedHue) > 15f,
                )
            }
        }
    }

    @Test
    fun neutralSurfacesCarryTheSeedsHint() {
        for (dark in listOf(false, true)) {
            val s = branded(dark)
            val base = baseline(dark)
            assertNotEquals(
                "surface (dark=$dark) is still Material baseline",
                base.surface.argb(), s.surface.argb(),
            )
            assertNotEquals(
                "surfaceVariant (dark=$dark) is still Material baseline",
                base.surfaceVariant.argb(), s.surfaceVariant.argb(),
            )
            assertCoolHint("surface (dark=$dark)", s.surface)
            assertCoolHint("surfaceVariant (dark=$dark)", s.surfaceVariant)
        }
    }

    @Test
    fun errorFamilyNeverFollowsTheSeed() {
        for (dark in listOf(false, true)) {
            val s = branded(dark)
            val base = baseline(dark)
            assertEquals("error moved under a brand", base.error.argb(), s.error.argb())
            assertEquals("onError moved under a brand", base.onError.argb(), s.onError.argb())
            assertEquals(
                "errorContainer moved under a brand",
                base.errorContainer.argb(), s.errorContainer.argb(),
            )
            assertEquals(
                "onErrorContainer moved under a brand",
                base.onErrorContainer.argb(), s.onErrorContainer.argb(),
            )
        }
    }

    @Test
    fun primaryFamilyStillFollowsTheSeed() {
        // The pre-existing half of the derivation, held so the four
        // palettes beside it cannot land by replacing it.
        for (dark in listOf(false, true)) {
            val s = branded(dark)
            val hue = hueOf(s.primary)!!
            assertTrue(
                "primary hue $hue is not near the seed's $seedHue (dark=$dark)",
                hueDistance(hue, seedHue) < 45f,
            )
            assertEquals(
                "surfaceTint is not primary",
                s.primary.argb(), s.surfaceTint.argb(),
            )
        }
    }

    @Test
    fun contrastStillLiftsRoleTones() {
        // The reason the role machinery is kaya's own: a static scheme
        // ignores the contrast slider (MDC #3524).
        val normal = branded(dark = false, contrast = 0f)
        val high = branded(dark = false, contrast = 1f)
        fun luminance(c: Color): Double {
            val argb = c.argb()
            fun chan(v: Int): Double {
                val s = v / 255.0
                return if (s <= 0.03928) s / 12.92 else Math.pow((s + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * chan((argb shr 16) and 0xFF) +
                0.7152 * chan((argb shr 8) and 0xFF) +
                0.0722 * chan(argb and 0xFF)
        }
        fun ratio(a: Color, b: Color): Double {
            val la = luminance(a)
            val lb = luminance(b)
            return (maxOf(la, lb) + 0.05) / (minOf(la, lb) + 0.05)
        }
        // WHAT THE SLIDER PROMISES is the container clearing its PAGE
        // (the container curve's high value is 4.5 against surface); a
        // foreground against a mid-tone container CANNOT reach its
        // curve's 11 and Material clamps to the best reachable side, so
        // 7:1 is not available of that pair (kayaRoleTone's own doc).
        val normalPage = ratio(normal.secondaryContainer, normal.surface)
        val highPage = ratio(high.secondaryContainer, high.surface)
        assertTrue(
            "the contrast slider did not move secondaryContainer off its page " +
                "(normal $normalPage, high $highPage)",
            highPage > normalPage,
        )
        assertTrue("high-contrast container/page ratio $highPage is below 4.5", highPage >= 4.5)
        val highOn = ratio(high.onSecondaryContainer, high.secondaryContainer)
        assertTrue(
            "high-contrast onSecondaryContainer ($highOn) fell below the 4.5 " +
                "the clamped best side reaches",
            highOn >= 4.5,
        )
    }
}
