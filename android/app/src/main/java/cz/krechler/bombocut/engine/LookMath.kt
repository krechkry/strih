// The Adjust light / color math of Bombocut/Engine/EffectsRenderer.swift (`color`), on one pixel, in the
// compositor's working space (Rec. 709 encoded values, 0...1). The reference for the GPU shader (LookShader.kt);
// checked against the iPhone's own renders (shared/parity/colors.json, ColorParityTest).
package cz.krechler.bombocut.engine

import cz.krechler.bombocut.model.Effects
import kotlin.math.pow

object LookMath {
    /** Rec. 709 luma (Core Image's CIColorControls). */
    private const val LR = 0.2125; private const val LG = 0.7154; private const val LB = 0.0721

    fun color(rgb: DoubleArray, e: Effects): DoubleArray {
        var c = rgb.copyOf()
        if (e.exposure != 0.0) {
            // CIExposureAdjust: times 2^EV, EV = exposure * 2 (on linear light)
            val k = 2.0.pow(e.exposure * 2)
            c = fromLinear(toLinear(c).map { it * k }.toDoubleArray())
        }
        if (e.contrast != 0.0 || e.saturation != 0.0) {
            // CIColorControls: saturation around luma, then contrast around 0.5
            val sat = 1 + e.saturation
            val con = 1 + e.contrast * 0.5
            val l = c[0] * LR + c[1] * LG + c[2] * LB
            c = DoubleArray(3) { l + (c[it] - l) * sat }
            c = DoubleArray(3) { (c[it] - 0.5) * con + 0.5 }
        }
        if (e.temperature != 0.0 || e.tint != 0.0) c = temperatureTint(c, 6500 + e.temperature * 3000, e.tint * 60)
        if (e.highlights != 0.0 || e.shadows != 0.0) {
            // the tone curve works in sRGB, like the eye sees it
            val s = srgbEncode(toLinear(c))
            c = fromLinear(srgbDecode(DoubleArray(3) { ToneLift.value(s[it], e.shadows, e.highlights) }))
        }
        return DoubleArray(3) { c[it].coerceIn(0.0, 1.0) }
    }

    // MARK: Temperature and tint (CITemperatureAndTint: the scene was lit by `neutral`, show it as 6500 K)

    private fun temperatureTint(c: DoubleArray, kelvin: Double, tint: Double): DoubleArray {
        val src = whiteXYZ(kelvin, tint)
        val dst = whiteXYZ(6500.0, 0.0)
        // von Kries in Bradford cone space, on linear light
        val bs = mul(BRADFORD, src); val bd = mul(BRADFORD, dst)
        val lin = toLinear(c)
        val xyz = mul(RGB2XYZ, lin)
        val cone = mul(BRADFORD, xyz)
        val adapted = DoubleArray(3) { cone[it] * bd[it] / bs[it] }
        return fromLinear(mul(XYZ2RGB, mul(BRADFORD_INV, adapted)))
    }

    /** White point of a light at `kelvin` (Planckian locus, Kim et al.), shifted along the isotherm by tint (Duv*3000). */
    private fun whiteXYZ(kelvin: Double, tint: Double): DoubleArray {
        val t = kelvin.coerceIn(1667.0, 25000.0)
        val x = if (t <= 4000) -0.2661239e9 / t.pow(3) - 0.2343589e6 / t.pow(2) + 0.8776956e3 / t + 0.179910
                else -3.0258469e9 / t.pow(3) + 2.1070379e6 / t.pow(2) + 0.2226347e3 / t + 0.240390
        val y = when {
            t <= 2222 -> -1.1063814 * x.pow(3) - 1.34811020 * x.pow(2) + 2.18555832 * x - 0.20219683
            t <= 4000 -> -0.9549476 * x.pow(3) - 1.37418593 * x.pow(2) + 2.09137015 * x - 0.16748867
            else -> 3.0817580 * x.pow(3) - 5.87338670 * x.pow(2) + 3.75112997 * x - 0.37001483
        }
        // tint: green (-) ... magenta (+), perpendicular to the locus in uv
        var u = 4 * x / (-2 * x + 12 * y + 3)
        var v = 6 * y / (-2 * x + 12 * y + 3)
        val duv = -tint / 3000.0
        u += 0.0; v += duv
        val xx = 3 * u / (2 * u - 8 * v + 4)
        val yy = 2 * v / (2 * u - 8 * v + 4)
        return doubleArrayOf(xx / yy, 1.0, (1 - xx - yy) / yy)
    }

    private val RGB2XYZ = arrayOf(doubleArrayOf(0.4124, 0.3576, 0.1805), doubleArrayOf(0.2126, 0.7152, 0.0722), doubleArrayOf(0.0193, 0.1192, 0.9505))
    private val XYZ2RGB = arrayOf(doubleArrayOf(3.2406, -1.5372, -0.4986), doubleArrayOf(-0.9689, 1.8758, 0.0415), doubleArrayOf(0.0557, -0.2040, 1.0570))
    private val BRADFORD = arrayOf(doubleArrayOf(0.8951, 0.2664, -0.1614), doubleArrayOf(-0.7502, 1.7135, 0.0367), doubleArrayOf(0.0389, -0.0685, 1.0296))
    private val BRADFORD_INV = arrayOf(doubleArrayOf(0.9869929, -0.1470543, 0.1599627), doubleArrayOf(0.4323053, 0.5183603, 0.0492912), doubleArrayOf(-0.0085287, 0.0400428, 0.9684867))
    private fun mul(m: Array<DoubleArray>, v: DoubleArray) = DoubleArray(3) { m[it][0] * v[0] + m[it][1] * v[1] + m[it][2] * v[2] }

    // MARK: Transfer curves

    /** Rec. 709 (as Core Image's itur_709 space): encoded -> linear light. */
    fun toLinear(c: DoubleArray) = DoubleArray(3) { val v = c[it]; if (v < 0.081) v / 4.5 else ((v + 0.099) / 1.099).pow(1 / 0.45) }
    fun fromLinear(c: DoubleArray) = DoubleArray(3) { val v = maxOf(c[it], 0.0); if (v < 0.018) v * 4.5 else 1.099 * v.pow(0.45) - 0.099 }
    fun srgbEncode(c: DoubleArray) = DoubleArray(3) { val v = maxOf(c[it], 0.0); if (v <= 0.0031308) 12.92 * v else 1.055 * v.pow(1 / 2.4) - 0.055 }
    fun srgbDecode(c: DoubleArray) = DoubleArray(3) { val v = c[it]; if (v <= 0.04045) v / 12.92 else ((v + 0.055) / 1.055).pow(2.4) }
}

/** The Shadows / Highlights tone curve (EffectsRenderer.swift `ToneLift`), 1:1. */
object ToneLift {
    fun value(x: Double, shadows: Double, highlights: Double): Double {
        var y = x.coerceIn(0.0, 1.0)
        if (shadows != 0.0) y = lift(y, shadows)
        if (highlights != 0.0) y = 1 - lift(1 - y, -highlights)
        return y.coerceIn(0.0, 1.0)
    }

    private fun lift(x: Double, amount: Double): Double {
        val a = amount.coerceIn(-1.0, 1.0)
        val k = if (a > 0) 2.4 * a else 0.9 * a
        return x * (1 + k * (1 - x).pow(4))
    }
}
