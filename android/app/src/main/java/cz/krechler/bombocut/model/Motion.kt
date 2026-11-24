// Ported from Bombocut/Model/Motion.swift (iOS ad3827a): stabilization, tracking, subject masks.
@file:Suppress("EnumEntryName")
package cz.krechler.bombocut.model

import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.ln
import kotlin.math.sin

/** Camera path measured from the footage (shift as frame fractions, Core Image y-up; turn; log zoom). */
@Serializable
data class PathSample(val t: Double, val x: Double, val y: Double, val a: Double = 0.0, val z: Double = 0.0)

@Serializable
enum class StabMode { smooth, locked; val title: String get() = if (this == smooth) "Smooth" else "Locked" }

@Serializable
data class Stabilization(
    val strength: Double = 0.6,
    val path: List<PathSample> = emptyList(),
    val mode: StabMode = StabMode.smooth,
    val maxZoom: Double = 0.15,
) {
    /** Per-frame corrections and the one zoom for the whole clip that hides the edges. */
    fun curve(aspect: Double = 16.0 / 9): StabCurve? {
        if (path.size <= 2) return null
        val n = path.size
        val dt = maxOf((path[n - 1].t - path[0].t) / (n - 1), 1.0 / 120)
        val raw = listOf(path.map { it.x }, path.map { it.y }, path.map { it.a }, path.map { it.z })
        val target = when (mode) {
            StabMode.smooth -> { val sigma = (0.15 + strength * 1.6) / dt; raw.map { gauss(it, sigma) } }
            StabMode.locked -> raw.map { v -> List(n) { v.sum() / n } }
        }
        val c = Array(4) { k -> DoubleArray(n) { raw[k][it] - target[k][it] } }

        val limit = 1 + maxOf(0.0, maxZoom)
        var f = DoubleArray(n) { 1.0 }
        for (i in 0 until n) {
            val p = StabPose(c[0][i], c[1][i], c[2][i], c[3][i], 1.0)
            if (zoomNeeded(p, aspect) <= limit) continue
            var lo = 0.0; var hi = 1.0
            repeat(24) {
                val m = (lo + hi) / 2
                if (zoomNeeded(p.scaled(m), aspect) <= limit) lo = m else hi = m
            }
            f[i] = lo
        }
        val w = maxOf(1, swiftRound(0.25 / dt))
        val ff = f
        f = DoubleArray(n) { i -> (maxOf(0, i - w)..minOf(n - 1, i + w)).minOf { ff[it] } }
        f = gauss(f.toList(), 0.12 / dt).map { minOf(it, 1.0) }.toDoubleArray()
        for (k in 0 until 4) for (i in 0 until n) c[k][i] *= f[i]

        var crop = 1.0
        for (i in 0 until n) crop = maxOf(crop, zoomNeeded(StabPose(c[0][i], c[1][i], c[2][i], c[3][i], 1.0), aspect))
        return StabCurve(path.map { it.t }, c[0].toList(), c[1].toList(), c[2].toList(), c[3].toList(), minOf(crop, limit + 0.02))
    }

    companion object {
        /** Gaussian smoothing that holds the ends. */
        fun gauss(v: List<Double>, sigma: Double): List<Double> {
            val n = v.size
            if (n <= 1 || sigma <= 0.01) return v
            val radius = minOf(n - 1, ceil(sigma * 2.5).toInt())
            val weights = (0..radius).map { k -> exp(-(k * k).toDouble() / (2 * sigma * sigma)) }
            return List(n) { i ->
                var s = 0.0; var sw = 0.0
                for (k in -radius..radius) {
                    val j = (i + k).coerceIn(0, n - 1)
                    s += v[j] * weights[abs(k)]
                    sw += weights[abs(k)]
                }
                s / sw
            }
        }

        /** How much the corrected frame has to be zoomed so no edge shows (1 = none). */
        fun zoomNeeded(p: StabPose, aspect: Double): Double {
            val a = aspect
            val tx = p.x * a
            val ty = p.y
            val ca = cos(-p.a); val sa = sin(-p.a); val ez = exp(p.z)
            fun fits(crop: Double): Boolean {
                for ((cx, cy) in listOf(-a / 2 to -0.5, a / 2 to -0.5, a / 2 to 0.5, -a / 2 to 0.5)) {
                    val ux = cx / crop - tx; val uy = cy / crop - ty
                    val qx = (ca * ux - sa * uy) / ez; val qy = (sa * ux + ca * uy) / ez
                    if (abs(qx) > a / 2 + 1e-9 || abs(qy) > 0.5 + 1e-9) return false
                }
                return true
            }
            if (fits(1.0)) return 1.0
            var lo = 1.0; var hi = 4.0
            repeat(30) { val m = (lo + hi) / 2; if (fits(m)) hi = m else lo = m }
            return hi
        }
    }
}

/** One frame's correction: shift, turn, zoom (log), and the clip's zoom. */
data class StabPose(val x: Double, val y: Double, val a: Double, val z: Double, val crop: Double) {
    fun scaled(f: Double) = StabPose(x * f, y * f, a * f, z * f, crop)
}

data class StabCurve(val t: List<Double>, val x: List<Double>, val y: List<Double>, val a: List<Double>,
                     val z: List<Double>, val crop: Double) {
    fun pose(s: Double): StabPose {
        if (t.isEmpty()) return StabPose(0.0, 0.0, 0.0, 0.0, crop)
        fun at(i: Int) = StabPose(x[i], y[i], a[i], z[i], crop)
        if (s <= t.first()) return at(0)
        if (s >= t.last()) return at(t.size - 1)
        var lo = 0; var hi = t.size - 1
        while (hi - lo > 1) { val mid = (lo + hi) / 2; if (t[mid] <= s) lo = mid else hi = mid }
        val f = (s - t[lo]) / maxOf(t[hi] - t[lo], 1e-9)
        fun mix(v: List<Double>) = v[lo] + (v[hi] - v[lo]) * f
        return StabPose(mix(x), mix(y), mix(a), mix(z), crop)
    }
}

/** Where the tracked subject is (normalized source coordinates, top-left origin). */
@Serializable
data class TrackSample(val t: Double, val x: Double, val y: Double, val w: Double, val h: Double)

@Serializable
enum class FollowMode {
    off, center, inPlace;
    val title: String get() = when (this) { off -> "Off"; center -> "Keep centered"; inPlace -> "Keep in place" }
}

@Serializable
data class Tracking(
    val samples: List<TrackSample>,
    val mode: FollowMode = FollowMode.center,
    val smooth: Double = 0.5,
    val anchor: Double? = null,
    val noBorders: Boolean? = null,
    val retain: Double? = null,
) {
    /** Smoothed subject centers, ready for the compositor. */
    fun curve(): TrackCurve? {
        if (mode == FollowMode.off || samples.size <= 1) return null
        val n = samples.size
        val dt = maxOf((samples[n - 1].t - samples[0].t) / (n - 1), 1.0 / 120)
        val radius = minOf(n - 1, swiftRound((0.05 + smooth * 0.7) / dt))
        val xs = DoubleArray(n); val ys = DoubleArray(n)
        val sizes = DoubleArray(if (retain == null) 0 else n)
        for (i in 0 until n) {
            var sx = 0.0; var sy = 0.0; var ss = 0.0; var c = 0.0
            for (k in -radius..radius) {
                val j = (i + k).coerceIn(0, n - 1)
                sx += samples[j].x
                sy += samples[j].y
                if (retain != null) ss += ln(maxOf(samples[j].w * samples[j].h, 1e-6))
                c += 1
            }
            xs[i] = sx / c
            ys[i] = sy / c
            if (retain != null) sizes[i] = exp(ss / c / 2)
        }
        var curve = TrackCurve(samples.map { it.t }, xs.toList(), ys.toList(), mode, anchor ?: samples[0].t, noBorders ?: false)
        if (retain != null) {
            curve = curve.copy(size = sizes.toList(), retain = true)
            curve = curve.copy(refSize = curve.sizeAt(retain))
        }
        return curve.withSpan()
    }

    fun box(s: Double): TrackSample? {
        if (samples.isEmpty()) return null
        if (s <= samples[0].t) return samples[0]
        var lo = 0; var hi = samples.size - 1
        while (lo < hi) { val mid = (lo + hi + 1) / 2; if (samples[mid].t <= s) lo = mid else hi = mid - 1 }
        return samples[lo]
    }
}

/** Following a tracked subject at one moment (see Motion.swift's `Follow`). */
data class Follow(val now: Pair<Double, Double>, val start: Pair<Double, Double>, val mode: FollowMode,
                  val fill: Boolean, val span: Pair<Double, Double>, val grow: Double)

data class TrackCurve(
    val t: List<Double>, val x: List<Double>, val y: List<Double>, val mode: FollowMode, val anchor: Double,
    val noBorders: Boolean = false,
    val size: List<Double> = emptyList(),
    val retain: Boolean = false,
    val refSize: Double = 0.0,
    val spanX: Double = 0.0,
    val spanY: Double = 0.0,
) {
    val span: Pair<Double, Double> get() = spanX to spanY

    fun withSpan(): TrackCurve {
        val ref = if (mode == FollowMode.center) 0.5 to 0.5 else start
        return copy(spanX = x.maxOfOrNull { abs(it - ref.first) } ?: 0.0, spanY = y.maxOfOrNull { abs(it - ref.second) } ?: 0.0)
    }

    fun at(s: Double): Pair<Double, Double> {
        if (t.isEmpty()) return 0.5 to 0.5
        if (s <= t.first()) return x[0] to y[0]
        if (s >= t.last()) return x[x.size - 1] to y[y.size - 1]
        var lo = 0; var hi = t.size - 1
        while (hi - lo > 1) { val mid = (lo + hi) / 2; if (t[mid] <= s) lo = mid else hi = mid }
        val f = (s - t[lo]) / maxOf(t[hi] - t[lo], 1e-9)
        return (x[lo] + (x[hi] - x[lo]) * f) to (y[lo] + (y[hi] - y[lo]) * f)
    }

    val start: Pair<Double, Double> get() = at(anchor)

    fun sizeAt(s: Double): Double {
        if (size.size != t.size || t.isEmpty()) return 0.0
        if (s <= t.first()) return size[0]
        if (s >= t.last()) return size[size.size - 1]
        var lo = 0; var hi = t.size - 1
        while (hi - lo > 1) { val mid = (lo + hi) / 2; if (t[mid] <= s) lo = mid else hi = mid }
        val f = (s - t[lo]) / maxOf(t[hi] - t[lo], 1e-9)
        return size[lo] + (size[hi] - size[lo]) * f
    }

    fun follow(s: Double): Follow {
        var grow = 0.0
        if (retain && refSize > 0) {
            val now = sizeAt(s)
            grow = if (now > 0) (refSize / now).coerceIn(0.25, 4.0) else 1.0
        }
        return Follow(at(s), start, mode, noBorders && !retain, span, grow)
    }
}

/** Cut the subject out of the frame to treat the background separately. */
@Serializable(with = SubjectMaskSerializer::class)
data class SubjectMask(
    val kind: Kind = Kind.person,
    val blur: Double = 0.0,
    val dim: Double = 0.0,
    val desaturate: Double = 0.0,
    val feather: Double = 0.0,
    val grow: Double = 0.0,
    val invert: Boolean = false,
    val picks: MaskPicks? = null,
) {
    @Serializable
    enum class Kind {
        person, subject, custom;
        val title: String get() = when (this) { person -> "People"; subject -> "Main subject"; custom -> "Custom" }
        companion object { val offered = listOf(person, subject) }
    }
}

@Serializable
private data class SubjectMaskStored(
    val kind: SubjectMask.Kind? = null, val blur: Double? = null, val dim: Double? = null,
    val desaturate: Double? = null, val feather: Double? = null, val grow: Double? = null,
    val invert: Boolean? = null, val picks: MaskPicks? = null,
)

object SubjectMaskSerializer : KSerializer<SubjectMask> {
    private val stored = SubjectMaskStored.serializer()
    override val descriptor: SerialDescriptor = stored.descriptor
    override fun deserialize(decoder: Decoder): SubjectMask {
        val s = decoder.decodeSerializableValue(stored)
        // a stored mask without a feather got 0.15 (Swift's init(from:)); a new one starts at 0
        return SubjectMask(s.kind ?: SubjectMask.Kind.person, s.blur ?: 0.0, s.dim ?: 0.0, s.desaturate ?: 0.0,
                           s.feather ?: 0.15, s.grow ?: 0.0, s.invert ?: false, s.picks)
    }
    override fun serialize(encoder: Encoder, value: SubjectMask) {
        val v = value
        encoder.encodeSerializableValue(stored, SubjectMaskStored(v.kind, v.blur, v.dim, v.desaturate, v.feather, v.grow, v.invert, v.picks))
    }
}

/** One brush stroke of a custom mask (flat x0, y0, x1, y1, … on the upright source picture). */
@Serializable data class MaskStroke(val add: Boolean, val xy: List<Double>)

/** Where the picked objects are at one moment. */
@Serializable data class PickSample(val t: Double, val keep: List<Double>, val drop: List<Double>)

/** Custom mask: objects picked by painting on one frame. */
@Serializable
data class MaskPicks(val anchor: Double, val strokes: List<MaskStroke> = emptyList(), val samples: List<PickSample> = emptyList()) {
    val followed: Boolean get() = samples.isNotEmpty()
    val isEmpty: Boolean get() = strokes.all { !it.add }

    fun points(s: Double): Pair<List<Pair<Double, Double>>, List<Pair<Double, Double>>> {
        fun pts(f: List<Double>) = (0 until f.size - 1 step 2).map { f[it] to f[it + 1] }
        if (samples.isEmpty() || abs(s - anchor) < 0.02) {
            val k = mutableListOf<Pair<Double, Double>>(); val d = mutableListOf<Pair<Double, Double>>()
            for (st in strokes) if (st.add) k += pts(st.xy) else d += pts(st.xy)
            return k to d
        }
        var lo = 0; var hi = samples.size - 1
        if (s <= samples[lo].t) return pts(samples[lo].keep) to pts(samples[lo].drop)
        if (s >= samples[hi].t) return pts(samples[hi].keep) to pts(samples[hi].drop)
        while (hi - lo > 1) { val mid = (lo + hi) / 2; if (samples[mid].t <= s) lo = mid else hi = mid }
        val a = samples[lo]; val b = samples[hi]
        return (pts(a.keep) + pts(b.keep)) to (pts(a.drop) + pts(b.drop))
    }
}
