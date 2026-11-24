// Ported from Bombocut/Model/Audio.swift (iOS ad3827a). Part 1: Fade. AudioItem follows.
package cz.krechler.bombocut.model

/** Fade in / out lengths that fit a stretch of `length` seconds (each at most half of it). */
object Fade {
    const val most = 5.0

    fun fit(fin: Double, fout: Double, length: Double): Pair<Double, Double> {
        val half = maxOf(0.0, length / 2)
        return minOf(maxOf(fin, 0.0), half) to minOf(maxOf(fout, 0.0), half)
    }

    /** The gain at local time `t` of a stretch with these fades (0...1), for drawing the shape. */
    fun gain(t: Double, length: Double, fades: Pair<Double, Double>): Double {
        var g = 1.0
        val (fi, fo) = fades
        if (fi > 0.001 && t < fi) g = minOf(g, maxOf(0.0, t / fi))
        if (fo > 0.001 && t > length - fo) g = minOf(g, maxOf(0.0, (length - t) / fo))
        return g
    }
}

/** The forward sound a reversed sound item was made from. */
@kotlinx.serialization.Serializable
data class AudioReverse(val file: String, val sourceDuration: Double)

/** A piece of sound on its own lane under the clips: music from Files, or sound taken out of a video. */
@kotlinx.serialization.Serializable
data class AudioItem(
    @kotlinx.serialization.Serializable(with = UUIDSerializer::class) val id: java.util.UUID = java.util.UUID.randomUUID(),
    val file: String,
    val name: String,
    val sourceDuration: Double,
    val inPoint: Double = 0.0,
    val start: Double,
    val duration: Double,
    val speed: Double = 1.0,
    val volume: Double = 1.0,
    val fadeIn: Double? = null,
    val fadeOut: Double? = null,
    val speech: SpeechFX? = null,
    val reverse: AudioReverse? = null,
    /** Beats: markers on the song's beats; clip edges, texts and sounds snap to them. */
    val beatsOn: Boolean? = null,
) {
    val end: Double get() = start + duration
    val fades: Pair<Double, Double> get() = Fade.fit(fadeIn ?: 0.0, fadeOut ?: 0.0, duration)
}
