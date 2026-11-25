// Ported 1:1 from CaptionCutter + Captions.recut / restyle / absorbEdits in Bombocut/Model/Captions.swift
// (iOS ad3827a). Turns timed words into readable caption lines (same rules as Titulky). Checked against the
// iPhone by CaptionParityTest (shared/parity/captions.json).
package cz.krechler.bombocut.model

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

object CaptionCutter {
    // Czech / Slovak: don't leave single-letter prepositions or conjunctions at a line end.
    private val noEnd = setOf("a", "i", "v", "ve", "s", "se", "z", "ze", "k", "ke", "o", "u", "na", "do", "po",
                              "za", "pro", "že", "ale", "aby", "když", "vo", "zo", "so", "pre", "ak")

    private fun endsSentence(w: String): Boolean {
        val last = w.trim('"', '“', '”', '»', '\'').lastOrNull() ?: return false
        return last in ".?!…"
    }

    private fun endsSoft(w: String): Boolean {
        val last = w.lastOrNull() ?: return false
        return last in ",;:–"
    }

    // Words that open a new clause or phrase: a good place for a new line to start (cs, sk, en).
    private val clauseStart = setOf(
        "a", "ale", "ani", "nebo", "či", "že", "protože", "proto", "takže", "když", "kdyby", "aby", "jestli", "pokud",
        "který", "která", "které", "kteří", "kterou", "kterým", "co", "kde", "jak", "až", "než", "však", "pak", "potom",
        "alebo", "ktorý", "ktorá", "ktoré", "ktorí", "pretože", "lebo", "keď", "keby", "ako",
        "and", "but", "or", "so", "because", "that", "which", "who", "when", "if", "then", "while", "although",
        "though", "until", "before", "after", "where",
    )

    /** Swift's .punctuationCharacters (Unicode P* categories), trimmed from both ends. */
    private fun trimPunctuation(s: String): String {
        fun p(c: Char) = when (Character.getType(c).toByte()) {
            Character.CONNECTOR_PUNCTUATION, Character.DASH_PUNCTUATION, Character.START_PUNCTUATION,
            Character.END_PUNCTUATION, Character.INITIAL_QUOTE_PUNCTUATION, Character.FINAL_QUOTE_PUNCTUATION,
            Character.OTHER_PUNCTUATION -> true
            else -> false
        }
        return s.trim { p(it) }
    }

    /** Swift counts characters (grapheme clusters); for words that is the code points. */
    private fun count(s: String) = s.codePointCount(0, s.length)

    private class Limits(style: CaptionStyle) {
        val lines = max(1, style.lines)
        val chars = style.maxChars * lines
        val maxDur = if (lines == 1) 2.4 else 6.0
        val gap = if (lines == 1) 0.5 else 0.8
        val minDur = if (lines == 1) 0.4 else 1.0
    }

    fun cues(words: List<CaptionWord>, style: CaptionStyle, cuts: List<Double> = emptyList()): List<CaptionCue> {
        val lim = Limits(style)
        val out = mutableListOf<List<CaptionWord>>()
        for (chunk in chunks(words, cuts)) out += if (style.naturalBreaks) naturalGroups(chunk, lim) else greedyGroups(chunk, lim)
        return finish(out, style, lim)
    }

    /** Your own splits first: the words on each side of one never share a line. */
    private fun chunks(words: List<CaptionWord>, cuts: List<Double>): List<List<CaptionWord>> {
        if (cuts.isEmpty()) return listOf(words)
        val out = mutableListOf<List<CaptionWord>>()
        var cur = mutableListOf<CaptionWord>()
        var next = 0
        val sorted = cuts.sorted()
        for (w in words) {
            val mid = (w.start + w.end) / 2
            var crossed = false
            while (next < sorted.size && sorted[next] < mid) { next++; crossed = true }
            if (crossed && cur.isNotEmpty()) { out.add(cur); cur = mutableListOf() }
            cur.add(w)
        }
        if (cur.isNotEmpty()) out.add(cur)
        return out
    }

    private fun length(ws: List<CaptionWord>): Int = ws.sumOf { count(it.text) } + max(0, ws.size - 1)

    private fun naturalGroups(words: List<CaptionWord>, lim: Limits): List<List<CaptionWord>> {
        val out = mutableListOf<List<CaptionWord>>()
        var run = mutableListOf<CaptionWord>()
        for (w in words) {
            val last = run.lastOrNull()
            if (last != null && w.start - last.end >= lim.gap) { out += bestCut(run, lim); run = mutableListOf() }
            run.add(w)
        }
        if (run.isNotEmpty()) out += bestCut(run, lim)
        return out
    }

    /** The cheapest way to cut one stretch of speech into lines (dynamic programming over the gaps). */
    private fun bestCut(ws: List<CaptionWord>, lim: Limits): List<List<CaptionWord>> {
        val n = ws.size
        if (n <= 1) return if (ws.isEmpty()) emptyList() else listOf(ws)
        val best = DoubleArray(n + 1) { Double.POSITIVE_INFINITY }
        val from = IntArray(n + 1)
        best[0] = 0.0
        for (j in 1..n) {
            for (i in j - 1 downTo 0) {
                if (best[i] == Double.POSITIVE_INFINITY) continue
                val piece = ws.subList(i, j)
                if (j - i > 1 && length(piece) > lim.chars) break   // longer starts only get longer
                val cost = best[i] + lineCost(piece, n, lim) + (if (j < n) gapCost(ws, j - 1) else 0.0)
                if (cost < best[j]) { best[j] = cost; from[j] = i }
            }
        }
        val groups = ArrayList<List<CaptionWord>>()
        var j = n
        while (j > 0) { val i = from[j]; groups.add(0, ws.subList(i, j).toList()); j = i }
        return groups
    }

    private fun lineCost(piece: List<CaptionWord>, all: Int, lim: Limits): Double {
        val len = length(piece).toDouble()
        val limit = lim.chars.toDouble()
        val fill = (len - limit * 0.8) / limit
        var cost = 3 * fill * fill
        if (piece.size == 1 && all > 1 && len < limit * 0.5) cost += 3.0   // a lonely word
        else if (len < limit * 0.35) cost += 1.5
        val dur = piece.last().end - piece.first().start
        if (piece.size > 1 && dur > lim.maxDur) cost += 8 + 10 * (dur - lim.maxDur)
        if (dur < lim.minDur * 0.6) cost += 1.0
        for (w in piece.dropLast(1)) if (endsSentence(w.text)) cost += 2.5   // a new sentence starts mid-line
        return cost
    }

    private fun gapCost(ws: List<CaptionWord>, k: Int): Double {
        val w = ws[k].text
        val next = ws[k + 1]
        var cost = 2.0
        if (endsSentence(w)) cost = 0.0
        else if (endsSoft(w)) cost = 0.7
        else if (trimPunctuation(next.text.lowercase()) in clauseStart) cost = 1.0
        cost -= min(1.0, max(0.0, next.start - ws[k].end - 0.15) * 3)
        if (w.lowercase() in noEnd) cost += 12.0
        return max(0.0, cost)
    }

    private fun greedyGroups(words: List<CaptionWord>, lim: Limits): List<List<CaptionWord>> {
        val limit = lim.chars
        val out = mutableListOf<List<CaptionWord>>()
        var cur = mutableListOf<CaptionWord>()
        var len = 0
        fun flush() { if (cur.isNotEmpty()) out.add(cur); cur = mutableListOf(); len = 0 }
        for (w in words) {
            val last = cur.lastOrNull(); val first = cur.firstOrNull()
            if (last != null && first != null) {
                val nextLen = len + 1 + count(w.text)
                if (nextLen > limit || w.end - first.start > lim.maxDur) {
                    // forced cut: carry a dangling preposition over to the next cue
                    val carry = mutableListOf<CaptionWord>()
                    while (cur.size > 1 && cur.last().text.lowercase() in noEnd) carry.add(0, cur.removeAt(cur.size - 1))
                    flush()
                    for (c in carry) { cur.add(c); len += (if (len > 0) 1 else 0) + count(c.text) }
                } else if (w.start - last.end >= lim.gap) {
                    flush()
                } else if (endsSentence(last.text) && len.toDouble() >= min(limit * 0.3, 14.0)) {
                    flush()
                } else if (endsSoft(last.text) && len.toDouble() >= limit * 0.6) {
                    flush()
                }
            }
            cur.add(w)
            len += (if (len > 0) 1 else 0) + count(w.text)
        }
        flush()
        return out
    }

    private fun finish(out: List<List<CaptionWord>>, style: CaptionStyle, lim: Limits): List<CaptionCue> {
        val lines = max(1, style.lines)
        val cues = out.map { raw ->
            val ws = if (style.punctuation) raw else raw.mapNotNull { w ->
                val t = stripPunctuation(w.text)
                if (t.isEmpty()) null else w.copy(text = t)
            }
            CaptionCue(start = raw.first().start, end = raw.last().end,
                       text = wrap(ws.joinToString(" ") { it.text }, style.maxChars, lines), words = ws)
        }.toMutableList()
        // readable timing: a little tail, minimum length, never overlapping the next cue
        for (i in cues.indices) {
            var end = cues[i].end + 0.15
            if (end - cues[i].start < lim.minDur) end = cues[i].start + lim.minDur
            if (i + 1 < cues.size) end = min(end, cues[i + 1].start - 0.04)
            cues[i] = cues[i].copy(end = max(end, cues[i].start + 0.1))
        }
        return cues
    }

    /** Commas and full stops at word ends go (decimal numbers like 2.5 stay). */
    fun stripPunctuation(w: String): String {
        var t = w
        while (t.isNotEmpty() && t.last() in ",.…;") t = t.dropLast(1)
        return t
    }

    /** Balanced line breaks; never ends a line on a one-letter preposition. */
    fun wrap(text: String, maxChars: Int, lines: Int): String {
        val words = text.split(" ").filter { it.isNotEmpty() }
        val flat = words.joinToString(" ")
        if (count(flat) <= maxChars || lines < 2 || words.size < 2) return flat
        if (lines == 2) {
            var bestScore = Int.MAX_VALUE
            var bestText = flat
            for (k in 1 until words.size) {
                val a = words.subList(0, k).joinToString(" "); val b = words.subList(k, words.size).joinToString(" ")
                var score = abs(count(a) - count(b))
                if (max(count(a), count(b)) > maxChars) score += 1000
                val l = words[k - 1].lastOrNull()
                if (l != null && l in ",.;:?!…") score -= 6
                if (words[k - 1].lowercase() in noEnd) score += 12
                if (words[k].lowercase() in clauseStart) score -= 3
                if (score < bestScore) { bestScore = score; bestText = a + "\n" + b }
            }
            return bestText
        }
        val out = mutableListOf<String>()
        var line = ""
        for (w in words) {
            if (line.isNotEmpty() && count(line) + 1 + count(w) > maxChars) { out.add(line); line = w }
            else line = if (line.isEmpty()) w else "$line $w"
        }
        if (line.isNotEmpty()) out.add(line)
        return out.joinToString("\n")
    }
}

/** Swift Captions.absorbEdits: lines you touched win over the words under them; untouched lines keep their words. */
fun Captions.absorbedEdits(): Captions {
    if (cues.isEmpty()) return this
    fun same(a: List<CaptionWord>, b: List<CaptionWord>) = a.size == b.size &&
        a.zip(b).all { (x, y) -> x.text == y.text && abs(x.start - y.start) < 0.005 && abs(x.end - y.end) < 0.005 }
    val out = mutableListOf<CaptionWord>()
    for (cue in cues.sortedBy { it.start }) {
        val inside = words.filter { val m = (it.start + it.end) / 2; m >= cue.start - 0.001 && m <= cue.end + 0.001 }
        val shown = if (style.punctuation) inside else inside.mapNotNull { w ->
            val t = CaptionCutter.stripPunctuation(w.text); if (t.isEmpty()) null else w.copy(text = t)
        }
        out += if (same(shown, cue.words)) inside else cue.words
    }
    return copy(words = out.sortedBy { it.start })
}

/**
 * Swift Captions.replaceWords(ofCue:with:): the words heard again go into that one line (and the words under it);
 * null when nothing heard falls inside the line. Your edits elsewhere are kept (absorbed first).
 */
fun Captions.replacingWords(id: java.util.UUID, heard: List<CaptionWord>): Captions? {
    val a = absorbedEdits()
    val i = a.cues.indexOfFirst { it.id == id }
    if (i < 0) return null
    val lo = a.cues[i].start - 0.001; val hi = a.cues[i].end + 0.001
    fun inside(w: CaptionWord): Boolean { val m = (w.start + w.end) / 2; return m >= lo && m <= hi }
    val fresh = heard.filter(::inside)
    if (fresh.isEmpty()) return null
    val words = (a.words.filter { !inside(it) } + fresh).sortedBy { it.start }
    val shown = if (a.style.punctuation) fresh else fresh.mapNotNull { w ->
        val t = CaptionCutter.stripPunctuation(w.text); if (t.isEmpty()) null else w.copy(text = t)
    }
    val text = CaptionCutter.wrap(shown.joinToString(" ") { it.text }, a.style.maxChars, maxOf(1, a.style.lines))
    return a.copy(words = words, cues = a.cues.toMutableList().also { it[i] = it[i].copy(words = shown, text = text) })
}

/** Swift Captions.restyle: edits go into the words first, then the style changes and the lines are cut again. */
fun Captions.restyled(change: (CaptionStyle) -> CaptionStyle): Captions {
    val a = absorbedEdits()
    val s = change(a.style)
    return a.copy(style = s, cues = CaptionCutter.cues(a.words, s, a.cuts ?: emptyList()))
}
