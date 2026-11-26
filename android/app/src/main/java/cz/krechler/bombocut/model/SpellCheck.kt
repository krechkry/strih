// Ported from Bombocut/Engine/Speech.swift (iOS a28b16c), enum SpellCheck: applyNames and czech 1:1 (fold, sameCase,
// distance, czechRules, czechSpellings). Not ported: `fix` (unsure word -> closest dictionary word). iOS only touches
// words the model was unsure of; sherpa-onnx's Android API gives no per-word confidence, and "not in the word list"
// in its place swapped right words for wrong ones on a real Czech clip (strih/android-captions-real-test.md).
// The Czech dictionary (iOS: UITextChecker) is a word list: engine/CzechWords.kt.
package cz.krechler.bombocut.model

import java.text.Normalizer

object SpellCheck {
    private const val PUNCT = ".,!?…;:\"'«»„“”()[]{}-–—/\\*&%$#@+=<>|~^_`"

    /** The word without punctuation and symbols around it (Swift trimmingCharacters(in: .punctuationCharacters.union(.symbols))). */
    private fun core(text: String) = text.trim { it in PUNCT || !it.isLetterOrDigit() && !it.isWhitespace() }

    /**
     * Czech picked, but the model now and then writes a word the Polish or Slovak way ("najdesz", "môžeš"). A word the
     * Czech dictionary doesn't know is spelled again the Czech way and swapped only when that gives a real Czech word.
     */
    fun czech(words: List<CaptionWord>, keep: Set<String>, known: (String) -> Boolean): List<CaptionWord> = words.map { w ->
        val core = core(w.text)
        if (core.length < 2 || !core.all { it.isLetter() } || core.lowercase() in keep || known(core.lowercase())) return@map w
        for (c in czechSpellings(core.lowercase())) {
            if (c != core.lowercase() && known(c)) return@map w.copy(text = w.text.replace(core, sameCase(c, core)))
        }
        w
    }

    /** Polish and Slovak spellings of a sound, written the Czech way. */
    val czechRules = listOf(
        "sz" to "š", "cz" to "č", "rz" to "ř", "ł" to "l", "ś" to "š", "ć" to "č", "ź" to "ž", "ż" to "ž",
        "ń" to "ň", "ó" to "ů", "ę" to "e", "ą" to "a", "w" to "v",
        "ä" to "e", "ô" to "ů", "ľ" to "l", "ĺ" to "l", "ŕ" to "r", "ia" to "ie",
    )

    /** Every rule at once first, then each one on its own (a word can need just one of them). */
    fun czechSpellings(w: String): List<String> {
        val rules = czechRules.filter { w.contains(it.first) && it.first != it.second }
        if (rules.isEmpty()) return emptyList()
        var all = w
        for ((a, b) in rules) all = all.replace(a, b)
        val out = mutableListOf(all)
        if (rules.size > 1) for ((a, b) in rules) out.add(w.replace(a, b))
        return out
    }

    /** Names and slang you typed win over what the model heard when they sound alike ("Krištof" -> "Kryštof"). */
    fun applyNames(words: List<CaptionWord>, names: List<String>): List<CaptionWord> {
        val list = names.filter { it.length >= 3 }.map { it to fold(it) }
        if (list.isEmpty()) return words
        return words.map { w ->
            val core = core(w.text)
            if (core.length < 3) return@map w
            val f = fold(core)
            var best: Pair<String, Int>? = null
            for ((name, nf) in list) {
                val d = distance(f, nf)
                if (d <= maxOf(1, nf.length / 4) && d < (best?.second ?: Int.MAX_VALUE)) best = name to d
            }
            val name = best?.first
            if (name == null || name == core) w else w.copy(text = w.text.replace(core, name))
        }
    }

    /** The typed names field split like iOS (spaces, commas, semicolons, new lines). */
    fun splitNames(typed: String): List<String> = typed.split(' ', ',', ';', '\n').filter { it.isNotEmpty() }

    fun fold(s: String): String =
        Normalizer.normalize(s, Normalizer.Form.NFD).filter { Character.getType(it) != Character.NON_SPACING_MARK.toInt() }.lowercase()

    private fun sameCase(g: String, w: String): String {
        val f = w.firstOrNull() ?: return g
        if (!f.isUpperCase()) return g
        if (w.length > 1 && w.all { !it.isLetter() || it.isUpperCase() }) return g.uppercase()
        return g.take(1).uppercase() + g.drop(1)
    }

    /** Edit distance (insert, delete, substitute). */
    fun distance(a: String, b: String): Int {
        if (a.isEmpty()) return b.length
        if (b.isEmpty()) return a.length
        var prev = IntArray(b.length + 1) { it }
        var cur = IntArray(b.length + 1)
        for (i in 1..a.length) {
            cur[0] = i
            for (j in 1..b.length) cur[j] = minOf(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + if (a[i - 1] == b[j - 1]) 0 else 1)
            val t = prev; prev = cur; cur = t
        }
        return prev[b.length]
    }
}
