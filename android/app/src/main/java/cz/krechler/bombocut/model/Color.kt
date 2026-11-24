// Ported from Bombocut/Model/Captions.swift (RGBA).
package cz.krechler.bombocut.model

import kotlinx.serialization.Serializable
import kotlin.math.abs

@Serializable
data class RGBA(val r: Double, val g: Double, val b: Double, val a: Double = 1.0) {
    fun near(o: RGBA) = abs(r - o.r) < 0.01 && abs(g - o.g) < 0.01 && abs(b - o.b) < 0.01

    companion object {
        val white = RGBA(1.0, 1.0, 1.0)
        val black = RGBA(0.0, 0.0, 0.0)
        val lime = RGBA(0.894, 1.0, 0.353)
        val yellow = RGBA(1.0, 0.86, 0.1)
        val red = RGBA(1.0, 0.25, 0.25)
        val pink = RGBA(1.0, 0.42, 0.75)
        val cyan = RGBA(0.3, 0.9, 1.0)
        val blue = RGBA(0.2, 0.45, 1.0)
        val offWhite = RGBA(0.9, 0.9, 0.88)
        val skin = RGBA(0.91, 0.76, 0.63)
        val offBlack = RGBA(0.1, 0.1, 0.1)
        val subtitleYellow = RGBA(1.0, 0.85, 0.16)
        val vibrantRed = RGBA(0.96, 0.14, 0.2)
        val palette = listOf(white, offWhite, skin, black, offBlack, subtitleYellow, vibrantRed, lime)
    }
}
