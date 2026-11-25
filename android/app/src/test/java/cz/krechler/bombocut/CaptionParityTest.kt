package cz.krechler.bombocut

import cz.krechler.bombocut.model.BomboJson
import cz.krechler.bombocut.model.CaptionCue
import cz.krechler.bombocut.model.CaptionCutter
import cz.krechler.bombocut.model.CaptionStyle
import cz.krechler.bombocut.model.CaptionWord
import cz.krechler.bombocut.model.Captions
import cz.krechler.bombocut.model.restyled
import kotlinx.serialization.Serializable
import org.junit.Assert.assertEquals
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import kotlin.math.abs

/**
 * shared/parity/captions.json: the iPhone's caption lines for the same timed words (1 or 2 lines, 16 / 26 / 42
 * characters, natural or greedy breaks, punctuation on or off, your own splits), lines wrapped, and an edited line
 * surviving a new cut. Android must cut the same lines at the same times (new line ids are random: not compared).
 */
class CaptionParityTest {
    @Serializable data class CutCase(val name: String, val words: List<CaptionWord>, val style: CaptionStyle,
                                     val cuts: List<Double>, val cues: List<CaptionCue>)
    @Serializable data class RestyleCase(val name: String, val before: Captions, val lines: Int, val maxChars: Int, val after: Captions)
    @Serializable data class Fixture(val cuts: List<CutCase>, val restyles: List<RestyleCase>, val wraps: List<List<String>>)

    private val fixture: Fixture by lazy {
        val f = File("../../shared/parity/captions.json")
        assumeTrue("fixtures not written yet", f.exists())
        BomboJson.decodeFromString(Fixture.serializer(), f.readText())
    }

    private fun sameCues(name: String, want: List<CaptionCue>, got: List<CaptionCue>) {
        assertEquals("$name: line count\n want ${want.map { it.text }}\n got  ${got.map { it.text }}", want.size, got.size)
        for ((w, g) in want.zip(got)) {
            assertEquals("$name: text", w.text, g.text)
            assert(abs(w.start - g.start) < 1e-9 && abs(w.end - g.end) < 1e-9) { "$name: '${w.text}' at ${g.start}..${g.end}, iPhone ${w.start}..${w.end}" }
            assertEquals("$name: words of '${w.text}'", w.words.map { it.text }, g.words.map { it.text })
        }
    }

    @Test fun cutsLikeTheIPhone() {
        for (c in fixture.cuts) sameCues(c.name, c.cues, CaptionCutter.cues(c.words, c.style, c.cuts))
    }

    @Test fun wrapsLikeTheIPhone() {
        for (w in fixture.wraps) assertEquals("wrap ${w[1]} x ${w[2]}", w[3], CaptionCutter.wrap(w[0], w[1].toInt(), w[2].toInt()))
    }

    @Test fun editsSurviveANewCut() {
        for (r in fixture.restyles) {
            val got = r.before.restyled { it.copy(lines = r.lines, maxChars = r.maxChars) }
            assertEquals("${r.name}: words", r.after.words.map { it.text }, got.words.map { it.text })
            sameCues(r.name, r.after.cues, got.cues)
        }
    }
}
