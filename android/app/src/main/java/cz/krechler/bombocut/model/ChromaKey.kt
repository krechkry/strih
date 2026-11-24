// Ported from Bombocut/Model/ChromaKey.swift (iOS ad3827a). The keyer math is the shader's reference.
package cz.krechler.bombocut.model

import kotlinx.serialization.Serializable

@Serializable
data class ChromaKey(
    val color: RGBA = green,
    val strength: Double = 0.6,
    val softness: Double = 0.3,
    val spill: Double = 0.35,
    val edge: Double = 0.0,
    val feather: Double = 0.0,
    val fillHoles: Double = 0.0,
) {
    enum class Screen { green, blue, picked }
    val screen: Screen get() = if (color.near(green)) Screen.green else if (color.near(blue)) Screen.blue else Screen.picked

    /** The key color's main channel (0 red, 1 green, 2 blue). */
    val channel: Int
        get() { val c = listOf(color.r, color.g, color.b); return c.indices.maxByOrNull { c[it] } ?: 1 }

    val fade: Double get() = 0.05 + 0.4 * softness
    val threshold: Double get() = maxOf(1 - 0.8 * strength, fade + 0.05)

    fun screenAmount(r: Double, g: Double, b: Double): Double {
        val ch = channel
        fun diff(v: List<Double>) = v[ch] - (v.indices.filter { it != ch }.maxOfOrNull { v[it] } ?: 0.0)
        val own = maxOf(diff(listOf(color.r, color.g, color.b)), 0.05)
        return diff(listOf(r, g, b)) / own
    }

    /** The matte (1 = keep, 0 = gone) and the color with the spill taken off. */
    fun key(r: Double, g: Double, b: Double): List<Double> {
        val e = screenAmount(r, g, b)
        val alpha = ((threshold - e) / fade).coerceIn(0.0, 1.0)
        if (spill <= 0.005) return listOf(alpha, r, g, b)
        val v = doubleArrayOf(r, g, b)
        val ch = channel
        val others = v.indices.filter { it != ch }.maxOf { v[it] }
        v[ch] -= spill * maxOf(0.0, v[ch] - others)
        return listOf(alpha, v[0], v[1], v[2])
    }

    companion object {
        val green = RGBA(0.15, 0.75, 0.3)
        val blue = RGBA(0.1, 0.3, 0.85)
    }
}
