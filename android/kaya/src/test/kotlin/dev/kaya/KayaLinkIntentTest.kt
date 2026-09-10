package dev.kaya

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * THE ONE-SHOT LINK READ (docs/app-links-plan.md §4), on the sequence no
 * leg can reach. A leg opens a link and reads the screen it named; what
 * it cannot see is the SECOND read of the same intent, because
 * `getIntent()` keeps handing that intent back at every later resume
 * (measured 2026-09-09, docs/traps.md) — so an arm that forgot to clear
 * would re-open the same link every time the app came forward, and every
 * assertion in links.steps would still pass. Nor can a leg see the null
 * case: a plain launch and a launcher tap both arrive at `onNewIntent`
 * with no data, and an arm that read "an intent arrived" as "a link
 * arrived" would hand the core an empty URL on every warm start.
 *
 * `read`/`clear` stand in for the Intent, which on a plain JVM is a stub
 * that throws.
 */
class KayaLinkIntentTest {

    /** One Intent's `data` field, readable and clearable. */
    private class Slot(var data: String?) {
        var clears = 0

        fun take(): String? = kayaTakeLink({ data }, { data = null; clears += 1 })
    }

    @Test
    fun theSameIntentAnswersExactlyOnce() {
        val slot = Slot("dev.kaya.aurora.notes://task/t1")
        assertEquals("dev.kaya.aurora.notes://task/t1", slot.take())
        assertEquals(1, slot.clears)
        // Every later resume reads the same intent back.
        assertNull(slot.take())
        assertNull(slot.take())
        assertEquals(1, slot.clears)
    }

    @Test
    fun anIntentWithNoDataIsNotALink() {
        val plainLaunch = Slot(null)
        assertNull(plainLaunch.take())
        // NOT CONSUMED: nothing was there, and clearing a field the arm
        // never read is how a real link that arrived in the same breath
        // would be lost.
        assertEquals(0, plainLaunch.clears)
    }

    /** An empty data string is no link either — a URL kaya would hand the
     * core and the core would announce as matching nothing. */
    @Test
    fun anEmptyUrlIsNotALink() {
        val empty = Slot("")
        assertNull(empty.take())
        assertEquals(0, empty.clears)
    }

    /** A second link after the first is delivered — the warm door fires
     * again, and the one-shot rule is per intent, not per process. */
    @Test
    fun aSecondLinkStillArrives() {
        val slot = Slot("dev.kaya.aurora.notes://task/t1")
        assertEquals("dev.kaya.aurora.notes://task/t1", slot.take())
        slot.data = "dev.kaya.aurora.notes://today"
        assertEquals("dev.kaya.aurora.notes://today", slot.take())
        assertEquals(2, slot.clears)
    }
}
