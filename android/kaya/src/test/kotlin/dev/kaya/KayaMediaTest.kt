package dev.kaya

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class KayaMediaTest {
    @Test
    fun aMediaTemplateTakesTheScenesTextWhereThisLanesTableNamesNothing() {
        val got = kayaExpandMedia("{media:vp9_opus.webm|ready 2.0s 160x90}, {captions:h264_tx3g.mp4|captions en [1]}")
        assertNull(got.refused)
        assertEquals("ready 2.0s 160x90, captions en [1]", got.text)
    }

    @Test
    fun aMalformedMediaTemplateIsRefusedWithHarnessRsSentence() {
        assertEquals("{media:nope} wants <item>|<text>", kayaExpandMedia("{media:nope}").refused)
        assertEquals(true, kayaExpandMedia("{captions:x|y").refused?.startsWith("unterminated {captions:"))
    }

    @Test
    fun aTrackLanguageIsBcp47AndUndWhenNoneIsNamed() {
        assertEquals("en", kayaLanguageTag("en"))
        assertEquals("fr", kayaLanguageTag("fr"))
        assertEquals("pt-BR", kayaLanguageTag("pt-br"))
        assertEquals("und", kayaLanguageTag(null))
        assertEquals("und", kayaLanguageTag(""))
        assertEquals("und", kayaLanguageTag("und"))
    }
}
