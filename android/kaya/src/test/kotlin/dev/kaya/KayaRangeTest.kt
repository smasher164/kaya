package dev.kaya

import androidx.compose.ui.geometry.Offset
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * THE RANGE'S READINGS (docs/range-plan.md §5): `expect_thumb` is measured
 * off the laid-out control in the root's space, so a rotated fader read from
 * the top, or a mirrored range read from the right, would still produce a
 * plausible fraction; and the spelling is harness.rs spelled_fraction's.
 */
class KayaRangeTest {

    @Test
    fun aTravelAcrossReadsFromTheLeftWhicheverEndIsTheMinimum() {
        val left = Offset(10f, 50f)
        val right = Offset(210f, 50f)
        assertEquals(0.2, kayaTravelFraction(left, right, Offset(50f, 50f))!!, 1e-6)
        assertEquals(0.2, kayaTravelFraction(right, left, Offset(50f, 50f))!!, 1e-6)
    }

    @Test
    fun aTravelStandingUpReadsFromTheBottom() {
        val bottom = Offset(40f, 448f)
        val top = Offset(40f, 248f)
        assertEquals(0.25, kayaTravelFraction(bottom, top, Offset(40f, 398f))!!, 1e-6)
        assertEquals(0.25, kayaTravelFraction(top, bottom, Offset(40f, 398f))!!, 1e-6)
        assertNull(kayaTravelFraction(top, top, top))
    }

    @Test
    fun theFractionIsSpelledAsTheHarnessSpellsIt() {
        assertEquals("0.2", kayaSpelledFraction(0.2))
        assertEquals("0.25", kayaSpelledFraction(0.2499))
        assertEquals("0", kayaSpelledFraction(-0.001))
        assertEquals("1", kayaSpelledFraction(1.0))
        assertEquals("0.8", kayaSpelledFraction(0.8000001))
    }

    @Test
    fun aTickIsReachedOnlyBetweenTheThumbs() {
        assertTrue(kayaRangeTickReached(0.5f, 0.2f, 0.8f))
        assertTrue(kayaRangeTickReached(0.2f, 0.2f, 0.8f))
        assertFalse(kayaRangeTickReached(0.1f, 0.2f, 0.8f))
        assertFalse(kayaRangeTickReached(0.9f, 0.2f, 0.8f))
    }
}
