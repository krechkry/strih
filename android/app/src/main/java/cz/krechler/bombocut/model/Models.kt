// Ported from Bombocut/Model/Models.swift (iOS ad3827a). Same names, same math.
// Part 1: ClipTransform, SpeedPoint, SpeedCurve, Retime, Canvas. Clip and Project follow.
package cz.krechler.bombocut.model

import cz.krechler.bombocut.app.Fmt
import kotlinx.serialization.Serializable
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.log2
import kotlin.math.pow
import kotlin.math.sqrt

/** Move / scale / rotate applied to a clip on the canvas (after fit or fill). */
@Serializable
data class ClipTransform(
    val x: Double = 0.0,          // offset as a fraction of canvas width, + = right
    val y: Double = 0.0,          // offset as a fraction of canvas height, + = down
    val scale: Double = 1.0,
    val rotation: Double = 0.0,   // radians, + = clockwise
) {
    val isIdentity: Boolean
        get() = abs(x) < 1e-4 && abs(y) < 1e-4 && abs(scale - 1) < 1e-4 && abs(rotation) < 1e-4
}

/** One point of a custom speed curve. */
@Serializable
data class SpeedPoint(
    val t: Double,   // 0...1 along the clip's source range
    val v: Double,   // speed multiplier
)

object SpeedCurve {
    const val minV = 0.05
    const val maxV = 15.0

    fun flat(v: Double = 1.0): List<SpeedPoint> {
        val c = v.coerceIn(minV, maxV)
        return listOf(0.0, 0.25, 0.5, 0.75, 1.0).map { SpeedPoint(it, c) }
    }

    /** Smooth curve through the points without overshoot (monotone cubic in log2 space). */
    fun value(pts: List<SpeedPoint>, u: Double): Double {
        val first = pts.firstOrNull() ?: return 1.0
        val n = pts.size
        if (n == 1 || u <= first.t) return first.v
        if (u >= pts[n - 1].t) return pts[n - 1].v
        val xs = pts.map { it.t }
        val ys = pts.map { log2(maxOf(it.v, 0.01)) }

        val d = DoubleArray(n - 1)
        for (i in 0 until n - 1) {
            val h = xs[i + 1] - xs[i]
            d[i] = if (h > 1e-9) (ys[i + 1] - ys[i]) / h else 0.0
        }
        val m = DoubleArray(n)
        m[0] = d[0]
        m[n - 1] = d[n - 2]
        if (n > 2) {
            for (i in 1 until n - 1) m[i] = if (d[i - 1] * d[i] <= 0) 0.0 else (d[i - 1] + d[i]) / 2
        }
        for (i in 0 until n - 1) {
            if (abs(d[i]) < 1e-12) {
                m[i] = 0.0
                m[i + 1] = 0.0
            } else {
                val a = m[i] / d[i]
                val b = m[i + 1] / d[i]
                val s = a * a + b * b
                if (s > 9) {
                    val tau = 3 / sqrt(s)
                    m[i] = tau * a * d[i]
                    m[i + 1] = tau * b * d[i]
                }
            }
        }

        var k = 0
        while (k < n - 2 && u > xs[k + 1]) k += 1
        val h = xs[k + 1] - xs[k]
        if (h <= 1e-9) return pts[k + 1].v
        val s = (u - xs[k]) / h
        val s2 = s * s
        val s3 = s2 * s
        val y = (2 * s3 - 3 * s2 + 1) * ys[k] + (s3 - 2 * s2 + s) * h * m[k] +
            (-2 * s3 + 3 * s2) * ys[k + 1] + (s3 - s2) * h * m[k + 1]
        return 2.0.pow(y).coerceIn(minV, maxV)
    }
}

/**
 * Maps timeline time inside a clip to source time, for constant speed or a curve.
 * The composition is built from exactly these segments, so durations always match
 * (on Android they become the pieces of a Media3 SpeedProvider).
 */
class Retime private constructor(val segs: List<Seg>, val outDuration: Double) {
    data class Seg(val src0: Double, val srcLen: Double, val out0: Double, val outLen: Double)

    companion object {
        /** Shortest piece the composition gets (output seconds), see Models.swift. */
        const val minPiece = 1.0 / 12

        /** `length` source seconds from `inPoint`, at `speed` or along `curve`. `factor`: the clip's Stack speed. */
        operator fun invoke(inPoint: Double, length: Double, curve: List<SpeedPoint>?, speed: Double = 1.0,
                            factor: Double = 1.0): Retime {
            val f = maxOf(factor, 0.01)
            val len = maxOf(0.0, length)
            if (curve != null && curve.size >= 2 && len > 0) {
                val n = minOf(240, maxOf(8, ceil(len * 12).toInt()))
                val step = len / n
                var out = 0.0
                val arr = ArrayList<Seg>(n)
                for (i in 0 until n) {
                    val v = SpeedCurve.value(curve, (i + 0.5) / n) * f
                    val ol = step / v
                    arr.add(Seg(inPoint + i * step, step, out, ol))
                    out += ol
                }
                return Retime(joined(arr), out)
            }
            val v = maxOf(speed * f, 0.01)
            return Retime(listOf(Seg(inPoint, len, 0.0, len / v)), len / v)
        }

        fun joined(fine: List<Seg>): List<Seg> {
            if (fine.isEmpty()) return fine
            var run = fine[0]
            val out = ArrayList<Seg>(fine.size)
            for (s in fine.drop(1)) {
                val runV = run.srcLen / maxOf(run.outLen, 1e-12)
                val v = s.srcLen / maxOf(s.outLen, 1e-12)
                run = if (run.outLen < minPiece || abs(v / runV - 1) < 0.02) {
                    run.copy(srcLen = run.srcLen + s.srcLen, outLen = run.outLen + s.outLen)
                } else {
                    out.add(run)
                    Seg(s.src0, s.srcLen, run.out0 + run.outLen, s.outLen)
                }
            }
            // a short last piece goes into the one before
            if (run.outLen < minPiece / 2 && out.isNotEmpty()) {
                val last = out.removeAt(out.size - 1)
                run = last.copy(srcLen = last.srcLen + run.srcLen, outLen = last.outLen + run.outLen)
            }
            out.add(run)
            return out
        }
    }

    private fun segIndex(t: Double): Int {
        var lo = 0
        var hi = segs.size - 1
        while (lo < hi) {
            val mid = (lo + hi + 1) / 2
            if (segs[mid].out0 <= t) lo = mid else hi = mid - 1
        }
        return lo
    }

    /** Source seconds shown at local time t (seconds from the clip's start on the timeline). */
    fun source(atLocal: Double): Double {
        if (segs.isEmpty()) return 0.0
        val t = atLocal.coerceIn(0.0, maxOf(0.0, outDuration))
        val s = segs[segIndex(t)]
        val f = if (s.outLen > 0) (t - s.out0) / s.outLen else 0.0
        return s.src0 + f.coerceIn(0.0, 1.0) * s.srcLen
    }

    /** Local timeline time at which source time x is shown. */
    fun local(atSource: Double): Double {
        if (segs.isEmpty()) return 0.0
        var lo = 0
        var hi = segs.size - 1
        while (lo < hi) {
            val mid = (lo + hi + 1) / 2
            if (segs[mid].src0 <= atSource) lo = mid else hi = mid - 1
        }
        val s = segs[lo]
        val f = if (s.srcLen > 0) (atSource - s.src0) / s.srcLen else 0.0
        return s.out0 + f.coerceIn(0.0, 1.0) * s.outLen
    }

    /** Playback speed at local time t. */
    fun speed(atLocal: Double): Double {
        if (segs.isEmpty()) return 1.0
        val s = segs[segIndex(atLocal.coerceIn(0.0, maxOf(0.0, outDuration)))]
        return if (s.outLen > 0) s.srcLen / s.outLen else 1.0
    }
}

/** Output frame shape. Stored as a ratio, real pixel size is picked at export. */
@Serializable
data class Canvas(val ratioW: Double = 9.0, val ratioH: Double = 16.0) {
    val aspect: Double get() = ratioW / maxOf(ratioH, 0.0001)

    /** Pixel size with the given short side, both sides rounded to even numbers (width, height). */
    fun size(shortSide: Int): Pair<Int, Int> {
        val s = shortSide.toDouble()
        val w: Double
        val h: Double
        if (aspect >= 1) { h = s; w = s * aspect } else { w = s; h = s / aspect }
        return even(w) to even(h)
    }

    val label: String
        get() {
            val presets = listOf(Triple(9.0, 16.0, "9:16"), Triple(16.0, 9.0, "16:9"), Triple(1.0, 1.0, "1:1"),
                Triple(4.0, 5.0, "4:5"), Triple(4.0, 3.0, "4:3"), Triple(3.0, 4.0, "3:4"),
                Triple(2.39, 1.0, "2.39:1"), Triple(21.0, 9.0, "21:9"))
            for ((w, h, l) in presets) if (abs(w / h - aspect) < 0.005) return l
            return Fmt.g(ratioW) + ":" + Fmt.g(ratioH)
        }

    companion object {
        /** Swift's `.rounded()` is half away from zero, like Math.round for positive values. */
        fun even(v: Double): Int = maxOf(2, swiftRound(v / 2) * 2)
    }
}

/** Swift `Double.rounded()`: to nearest, halves away from zero. */
fun swiftRound(v: Double): Int = if (v >= 0) kotlin.math.floor(v + 0.5).toInt() else -kotlin.math.floor(-v + 0.5).toInt()
