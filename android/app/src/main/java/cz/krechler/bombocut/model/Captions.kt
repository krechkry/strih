// Ported from Bombocut/Model/Captions.swift (iOS ad3827a). Part 1: the stored data. Line cutting
// (CaptionCutter), split / merge / restyle and the remap after edits come with the captions port.
@file:Suppress("EnumEntryName")
package cz.krechler.bombocut.model

import kotlinx.serialization.Serializable
import java.util.UUID

@Serializable
data class CaptionWord(val text: String, val start: Double, val end: Double, val confidence: Double? = null)

@Serializable
data class CaptionCue(
    @Serializable(with = UUIDSerializer::class) val id: UUID = UUID.randomUUID(),
    val start: Double,
    val end: Double,
    val text: String,
    val words: List<CaptionWord>,
) {
    /** Swift setText: the new text, its words spread evenly over the line (by letters), after a manual edit. */
    fun withText(t: String): CaptionCue {
        val tokens = t.split(' ', '\n').filter { it.isNotEmpty() }
        if (tokens.isEmpty()) return copy(text = t, words = emptyList())
        val total = tokens.sumOf { it.length }.toDouble()
        var cursor = start
        val ws = tokens.map { w ->
            val d = (end - start) * w.length / maxOf(total, 1.0)
            val word = CaptionWord(w, cursor, cursor + d)
            cursor += d
            word
        }
        return copy(text = t, words = ws)
    }
}

@Serializable enum class CaptionFont { heavy, rounded, condensed, avenir, futura, serif, typewriter, mono }

@Serializable
enum class CaptionAnim {
    none, fade, pop, slide, highlight, words, typewriter;
    val title: String
        get() = when (this) {
            none -> "None"; fade -> "Fade"; pop -> "Pop"; slide -> "Slide up"; highlight -> "Highlight"
            words -> "Word by word"; typewriter -> "Typewriter"
        }
}

@Serializable
data class CaptionStyle(
    val font: CaptionFont = CaptionFont.heavy,
    val fontName: String? = null,
    val fontWeight: Double? = null,
    val size: Double = 0.065,
    val text: RGBA = RGBA.white,
    val highlight: RGBA = RGBA.lime,
    val stroke: RGBA = RGBA.black,
    val strokeWidth: Double = 0.0,
    val strokeOutside: Boolean = true,
    val tracking: Double = 0.0,
    val lineSpacing: Double = 1.0,
    val box: Boolean = false,
    val boxColor: RGBA = RGBA.black,
    val boxOpacity: Double = 0.7,
    val shadow: Boolean = true,
    val shadowOpacity: Double = 0.75,
    val shadowBlur: Double = 0.18,
    val shadowAngle: Double = 90.0,
    val shadowDistance: Double = 0.05,
    val caps: Boolean = false,
    val y: Double = 0.72,
    val x: Double = 0.0,
    val rotation: Double = 0.0,
    val lines: Int = 2,
    val maxChars: Int = 32,
    val anim: CaptionAnim = CaptionAnim.fade,
    val punctuation: Boolean = false,
    val behindSubject: Boolean = false,
    val naturalBreaks: Boolean = true,
)

@Serializable
data class CaptionTemplate(
    @Serializable(with = UUIDSerializer::class) val id: UUID = UUID.randomUUID(),
    val name: String,
    val style: CaptionStyle,
    val builtIn: Boolean = false,
) {
    companion object {
        val builtIns = listOf(
            CaptionTemplate(UUID.fromString("00000000-0000-0000-0000-0000000000C1"), "Clean", CaptionStyle(anim = CaptionAnim.fade), true),
            CaptionTemplate(UUID.fromString("00000000-0000-0000-0000-0000000000C2"), "Punch", CaptionStyle(
                font = CaptionFont.heavy, caps = true, size = 0.085, strokeWidth = 0.6, shadow = false, lines = 1,
                maxChars = 16, y = 0.62, anim = CaptionAnim.highlight), true),
            CaptionTemplate(UUID.fromString("00000000-0000-0000-0000-0000000000C3"), "Box", CaptionStyle(
                font = CaptionFont.rounded, box = true, boxOpacity = 0.85, shadow = false, size = 0.055, y = 0.8,
                anim = CaptionAnim.slide), true),
        )
    }
}

@Serializable
data class Captions(
    val language: String,
    val words: List<CaptionWord>,
    val cues: List<CaptionCue>,
    val style: CaptionStyle,
    @Serializable(with = UUIDSerializer::class) val templateID: UUID? = null,
    val cuts: List<Double>? = null,
) {
    fun cue(t: Double): CaptionCue? {
        var lo = 0; var hi = cues.size - 1
        while (lo <= hi) {
            val mid = (lo + hi) / 2
            val c = cues[mid]
            if (t < c.start) hi = mid - 1 else if (t >= c.end) lo = mid + 1 else return c
        }
        return null
    }
}
