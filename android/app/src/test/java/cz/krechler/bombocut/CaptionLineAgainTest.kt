package cz.krechler.bombocut

import cz.krechler.bombocut.model.CaptionCutter
import cz.krechler.bombocut.model.CaptionStyle
import cz.krechler.bombocut.model.CaptionWord
import cz.krechler.bombocut.model.Captions
import cz.krechler.bombocut.model.replacingWords
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** One caption line heard again (iOS Captions.replaceWords(ofCue:with:)): only that line and its words change. */
class CaptionLineAgainTest {
    private fun w(t: String, a: Double, b: Double) = CaptionWord(t, a, b)

    private fun caps(): Captions {
        val words = listOf(w("Ahoj", 0.2, 0.5), w("lidi.", 0.5, 0.9), w("Tombo", 2.0, 2.4), w("su", 2.4, 2.6), w("posloucha.", 2.6, 3.2))
        val style = CaptionStyle(lines = 1, maxChars = 32)
        return Captions("cs", words, CaptionCutter.cues(words, style, listOf(1.5)), style)
    }

    @Test fun replacesOnlyThatLine() {
        val c = caps()
        assertEquals(2, c.cues.size)
        val second = c.cues[1]
        // heard with a little context on both sides: a word from the first line comes along and is ignored
        val heard = listOf(w("lidi.", 0.5, 0.9), w("Bombocut", 2.0, 2.5), w("poslouchá.", 2.6, 3.2))
        val fixed = c.replacingWords(second.id, heard)!!
        assertEquals(c.cues[0], fixed.cues[0])
        assertEquals("Bombocut poslouchá", fixed.cues[1].text)
        assertEquals(second.id, fixed.cues[1].id)
        assertEquals(listOf("Ahoj", "lidi.", "Bombocut", "poslouchá."), fixed.words.map { it.text })
    }

    @Test fun nothingHeardLeavesItAlone() {
        val c = caps()
        assertNull(c.replacingWords(c.cues[1].id, listOf(w("lidi.", 0.5, 0.9))))
        assertNull(c.replacingWords(c.cues[1].id, emptyList()))
    }
}
