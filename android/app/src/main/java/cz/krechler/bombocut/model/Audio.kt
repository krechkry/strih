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
