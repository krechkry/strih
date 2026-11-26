package cz.krechler.bombocut

import cz.krechler.bombocut.model.CaptionWord
import cz.krechler.bombocut.model.SpellCheck
import org.junit.Assert.assertEquals
import org.junit.Test
import java.util.zip.GZIPInputStream
import java.io.File

/** SpellCheck after the speech model (Swift SpellCheck.applyNames / czech), with the bundled Czech word list. */
class SpellCheckTest {
    private fun ws(vararg t: String) = t.mapIndexed { i, s -> CaptionWord(s, i * 0.5, i * 0.5 + 0.4, 1.0) }

    private val known: Set<String> by lazy {
        val f = listOf("src/main/assets/cs-words.txt.gz", "app/src/main/assets/cs-words.txt.gz").map(::File).first { it.exists() }
        GZIPInputStream(f.inputStream()).bufferedReader().readLines().toHashSet()
    }

    @Test fun typedNamesWin() {
        // heard on Krystof's real clip: "bombokat"; typed: BOMBOCUT
        val out = SpellCheck.applyNames(ws("stáhni", "si", "bombokat,", "Krištof"), SpellCheck.splitNames("BOMBOCUT, Kryštof"))
        assertEquals(listOf("stáhni", "si", "BOMBOCUT,", "Kryštof"), out.map { it.text })
        // short words and far words stay
        assertEquals(listOf("bomba", "se"), SpellCheck.applyNames(ws("bomba", "se"), listOf("BOMBOCUT")).map { it.text })
    }

    @Test fun polishAndSlovakSpellingsGoCzech() {
        val out = SpellCheck.czech(ws("Najdesz", "môžeš", "przed", "szkoła.", "wiem", "rozumiem", "móda", "web", "Mariana"), emptySet()) { it in known }
        // swapped only into a real Czech word; real Czech (móda) and words with no Czech twin stay
        assertEquals(listOf("Najdeš", "můžeš", "před", "škola.", "wiem", "rozumiem", "móda", "web", "Mariana"), out.map { it.text })
        // typed words are never touched
        assertEquals("môžeš", SpellCheck.czech(ws("môžeš"), setOf("môžeš")) { it in known }[0].text)
    }

    @Test fun wordListIsCzech() {
        for (w in listOf("zapnu", "stáhni", "napiš", "vaši", "můžeš", "škola", "před", "móda")) assertEquals(w, true, w in known)
        // Slovak that turns up in Czech subtitles is left out
        for (w in listOf("viem", "môžeš", "rozumiem", "teraz")) assertEquals(w, false, w in known)
    }

    @Test fun distanceAndFold() {
        assertEquals(2, SpellCheck.distance(SpellCheck.fold("bombokat"), SpellCheck.fold("BOMBOCUT")))
        assertEquals("krystof", SpellCheck.fold("Kryštof"))
    }
}
