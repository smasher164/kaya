package dev.kaya

import org.junit.Assert.assertEquals
import org.junit.Test
import java.util.TimeZone

/**
 * THE DATE DIALOG'S CONVENTION, on the one path no scene reaches
 * (docs/datetime-plan.md P2). PINNED TO LITERAL EPOCH MILLIS and not to
 * a round trip through this file's own writer — docs/traps.md, "A
 * round-trip test of a SYMMETRIC conversion measures nothing".
 */
class KayaPickerUtcTest {

    // (packed day, that day's 00:00:00Z in epoch millis).
    private val days = listOf(
        20260904L to 1788480000000L,
        20260101L to 1767225600000L,
        20261231L to 1798675200000L,
        20240229L to 1709164800000L,
    )

    private val zones = listOf(
        "America/Los_Angeles", // UTC-8: catches a systemDefault READ
        "Pacific/Kiritimati", // UTC+14: catches a systemDefault WRITE
        "Asia/Kolkata", // UTC+5:30
        "UTC",
    )

    @Test
    fun theStatesUtcMidnightIsWrittenAndReadInEveryDeviceZone() {
        val saved = TimeZone.getDefault()
        try {
            for (zone in zones) {
                TimeZone.setDefault(TimeZone.getTimeZone(zone))
                for ((packed, utcMidnight) in days) {
                    assertEquals(
                        "$zone: the state's millis for $packed",
                        utcMidnight,
                        kayaUtcMillisOf(packed),
                    )
                    assertEquals(
                        "$zone: the day read back from $utcMidnight",
                        packed,
                        kayaPackedOfUtcMillis(utcMidnight),
                    )
                }
            }
        } finally {
            TimeZone.setDefault(saved)
        }
    }
}
