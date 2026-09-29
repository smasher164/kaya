package dev.kaya

import org.junit.Assert.assertEquals
import org.junit.Test
import java.util.Locale

/**
 * THE NUMBER FIELD'S READING ON ANDROID (docs/number-field-plan.md §3 rule
 * 5, §7): the whole text or nothing. The host JVM has no android.icu, so
 * java.text stands in for the formatter; the ICU half is the numberfield
 * legs', whose German one reads the locale's separator.
 */
class KayaFormatParseTest {

    private fun reads(tag: String, text: String): String {
        val f = java.text.NumberFormat.getInstance(Locale.forLanguageTag(tag))
        f.isGroupingUsed = false
        return kayaWholeNumber(text) { s, at -> f.parse(s, at) }
    }

    private fun writes(tag: String, value: Double, digits: Int): String {
        val f = java.text.NumberFormat.getInstance(Locale.forLanguageTag(tag))
        f.isGroupingUsed = false
        f.minimumFractionDigits = digits
        f.maximumFractionDigits = digits
        return f.format(value)
    }

    @Test
    fun whatIsWrittenReadsBack() {
        for ((tag, value, digits) in listOf(
            Triple("en-US", 12.5, 1), Triple("de-DE", 12.5, 1),
            Triple("de-DE", 1234.25, 2), Triple("en-US", -40.0, 0),
        )) {
            val written = writes(tag, value, digits)
            val read = reads(tag, written).toDouble()
            assertEquals(tag, value, read, 0.0)
            assertEquals(tag, written, writes(tag, read, digits))
        }
    }

    @Test
    fun anythingButOneWholeNumberIsRefused() {
        assertEquals("", reads("en-US", "abc"))
        assertEquals("", reads("en-US", ""))
        assertEquals("", reads("en-US", "12.5abc"))
        assertEquals("", reads("en-US", "1,234.5"))
        assertEquals("", reads("de-DE", "12.5"))
    }
}
