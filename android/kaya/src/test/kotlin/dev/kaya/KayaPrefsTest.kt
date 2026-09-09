package dev.kaya

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * THE PREFERENCE STORE'S TYPE DISCIPLINE (docs/tasks-s4-plan.md §4), on
 * the values no leg reaches. A scene stores one integer; nothing anywhere
 * stores a float or a string, and nothing at all writes the shapes this
 * store can hold and kaya cannot — so the "another type answers ABSENT"
 * rule and the double's encoding are observable only here.
 */
class KayaPrefsTest {

    @Test
    fun eachTypeCrossesUnderItsOwnTag() {
        assertEquals("sa b", KayaPrefs.tagged("a b"))
        assertEquals("i42", KayaPrefs.tagged(42L))
        assertEquals("i-1", KayaPrefs.tagged(-1L))
        assertEquals("btrue", KayaPrefs.tagged(true))
        assertEquals("bfalse", KayaPrefs.tagged(false))
    }

    /**
     * A DOUBLE IS A ONE-ELEMENT STRING SET, holding the text Rust's
     * Display wrote: this store's float is 32-bit, so `putFloat` would
     * answer 0.1 back as 0.10000000149011612 while every other backing
     * answers 0.1, and `putLong(doubleToRawLongBits(v))` would read back
     * as an i64 where the rule says absent.
     */
    @Test
    fun aDoubleKeepsRustsOwnSpelling() {
        assertEquals("f1.5", KayaPrefs.tagged(setOf("1.5")))
        assertEquals("f0.1", KayaPrefs.tagged(setOf("0.1")))
        // Rust's Display for an integral f64, which is what was stored.
        assertEquals("f2", KayaPrefs.tagged(setOf("2")))
    }

    /** Absent, and a value kaya did not write, are one answer. */
    @Test
    fun anythingElseIsAbsent() {
        assertNull(KayaPrefs.tagged(null))
        assertNull(KayaPrefs.tagged(7))
        assertNull(KayaPrefs.tagged(1.5f))
        assertNull(KayaPrefs.tagged(setOf("a", "b")))
        assertNull(KayaPrefs.tagged(emptySet<String>()))
        assertNull(KayaPrefs.tagged(setOf(1L)))
    }
}
