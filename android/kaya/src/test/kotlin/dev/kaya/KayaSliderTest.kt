package dev.kaya

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * THE SLIDER'S ARITHMETIC, on the paths no leg reaches
 * (docs/slider-plan.md S1, S5). The scene sees the SNAP — a driven 37
 * lands on 35 — but nothing it can assert reads Material's interior-stop
 * count or a tick's position: both are pixels, and a slider drawing its
 * stops in the wrong places answers every observable exactly as this one
 * does.
 */
class KayaSliderTest {

    @Test
    fun materialsStepsCountTheInteriorStops() {
        assertEquals(19, kayaSliderSteps(0.0, 100.0, 5.0))
        assertEquals(3, kayaSliderSteps(0.0, 1.0, 0.25))
        assertEquals(63, kayaSliderSteps(8.0, 72.0, 1.0))
        // One interval has no interior stop, and a continuous slider has
        // none either — both are Material's 0.
        assertEquals(0, kayaSliderSteps(0.0, 100.0, 100.0))
        assertEquals(0, kayaSliderSteps(0.0, 1.0, 0.0))
    }

    @Test
    fun theLatticeStartsAtTheMinimumAndTheRangeBounds() {
        assertEquals(35.0, kayaSnappedSlider(37.0, 0.0, 100.0, 5.0), 1e-9)
        assertEquals(100.0, kayaSnappedSlider(140.0, 0.0, 100.0, 5.0), 1e-9)
        assertEquals(0.0, kayaSnappedSlider(-3.0, 0.0, 100.0, 5.0), 1e-9)
        // A continuous slider keeps what it is given.
        assertEquals(0.37, kayaSnappedSlider(0.37, 0.0, 1.0, 0.0), 1e-9)
        // FROM THE MINIMUM, never from zero: 1..4 by 1.5 rests on
        // {1, 2.5, 4}, and a lattice measured from zero would answer 1.5,
        // which is not a stop at all.
        assertEquals(2.5, kayaSnappedSlider(2.0, 1.0, 4.0, 1.5), 1e-9)
    }

    @Test
    fun ticksSitEverySpacingFromTheMinimumAndNowhereWhenThereIsNone() {
        assertEquals(
            listOf(0f, 0.25f, 0.5f, 0.75f, 1f),
            kayaSliderTickFractions(0.0, 100.0, 25.0),
        )
        assertEquals(
            listOf(0f, 0.25f, 0.5f, 0.75f, 1f),
            kayaSliderTickFractions(0.0, 1.0, 0.25),
        )
        // S5 ruled ticks EXPLICIT: a stepped slider with no spacing draws
        // none, which is why the arm suppresses Material's own.
        assertEquals(emptyList<Float>(), kayaSliderTickFractions(0.0, 100.0, 0.0))
    }
}
