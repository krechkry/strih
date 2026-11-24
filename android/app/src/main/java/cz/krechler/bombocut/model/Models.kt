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

/** Where a reversed clip came from: the original file and the part of it that was reversed. */
@Serializable
data class ReverseOrigin(val mediaFile: String, val sourceDuration: Double, val inPoint: Double, val outPoint: Double)

/**
 * One piece of source media placed on the timeline. Decoding is tolerant like iOS (see ClipSerializer).
 * Immutable: Swift's value semantics become copy() here, so an undo snapshot can never change under us.
 */
@OptIn(kotlinx.serialization.ExperimentalSerializationApi::class)
@kotlinx.serialization.KeepGeneratedSerializer
@Serializable(with = ClipSerializer::class)
data class Clip(
    @Serializable(with = UUIDSerializer::class) val id: java.util.UUID = java.util.UUID.randomUUID(),
    val mediaFile: String,
    val sourceDuration: Double,
    val inPoint: Double = 0.0,
    val outPoint: Double = sourceDuration,
    val volume: Double = 1.0,
    val fill: Boolean = false,
    val speed: Double = 1.0,
    val speedCurve: List<SpeedPoint>? = null,
    val pitchCorrect: Boolean = true,
    val curveSticks: Boolean? = null,
    val transform: ClipTransform = ClipTransform(),
    val aspect: Double? = null,
    val opacity: Double = 1.0,
    val effects: Effects = Effects(),
    val keyframes: List<Keyframe> = emptyList(),
    val stabilization: Stabilization? = null,
    val tracking: Tracking? = null,
    val smoothSlowMo: Boolean = false,
    val mask: SubjectMask? = null,
    val motionBlur: Double = 0.5,
    val motionBlurOn: Boolean = false,
    val blurDirection: BlurDirection = BlurDirection.both,
    val anim: AnimPair = AnimPair(),
    val cut: CutTransition? = null,
    val speech: SpeechFX? = null,
    val still: Boolean = false,
    val reversed: ReverseOrigin? = null,
    val asset: String? = null,
    val autoZoom: AutoZoom? = null,
    val stack: List<Clip>? = null,
    val crop: CropRect? = null,
    val fadeIn: Double = 0.0,
    val fadeOut: Double = 0.0,
    val filter: LookFilter? = null,
    val key: ChromaKey? = null,
    /** Its Stack's speed and motion blur (kept in step by `Project.syncStackSpeeds`, not saved). */
    @kotlinx.serialization.Transient val outerSpeed: Double = 1.0,
    @kotlinx.serialization.Transient val stackBlur: Double = 0.0,
) {
    val blurAmount: Double get() = maxOf(if (motionBlurOn) motionBlur else 0.0, stackBlur)
    val fades: Pair<Double, Double> get() = Fade.fit(fadeIn, fadeOut, duration)
    val rate: Double get() = maxOf(speed * outerSpeed, 0.01)
    val staticLook: Look get() = Look(transform, opacity, effects)
    fun withStaticLook(l: Look) = copy(transform = l.transform, opacity = l.opacity, effects = l.effects)

    /** Look at a source time (keyframes / static only; cheap, for the UI). */
    fun look(atSource: Double): Look = lookAt(staticLook, keyframes, atSource)

    val allMediaFiles: List<String>
        get() = listOf(mediaFile) + (reversed?.let { listOf(it.mediaFile) } ?: emptyList()) + (stack ?: emptyList()).flatMap { it.allMediaFiles }

    val retime: Retime get() = Retime(inPoint, outPoint - inPoint, speedCurve, speed, outerSpeed)

    val hasCurve: Boolean get() = (speedCurve?.size ?: 0) >= 2
    /** Length on the timeline. */
    val duration: Double get() = retime.outDuration

    val headHandle: Double
        get() = if (hasCurve || still || reversed != null || stack != null) 0.0 else maxOf(0.0, inPoint / rate)
    val tailHandle: Double
        get() = if (hasCurve || still || reversed != null || stack != null) 0.0 else maxOf(0.0, (sourceDuration - outPoint) / rate)

    fun withHandles(head: Double, tail: Double): Clip {
        if (!(head > 0 || tail > 0) || hasCurve) return this
        val v = rate
        return copy(inPoint = maxOf(0.0, inPoint - head * v), outPoint = minOf(sourceDuration, outPoint + tail * v))
    }

    val needsNeighbours: Boolean
        get() = blurAmount > 0.001 || (smoothSlowMo && retime.segs.any { it.outLen > it.srcLen * 1.05 })

    val sticksCurve: Boolean get() = curveSticks ?: Defaults.stickSpeedCurve

    /** `o`'s curve on this clip's source range with every point kept on its frame (see Models.swift). */
    fun stuckCurve(o: Clip): List<SpeedPoint>? {
        val pts = o.speedCurve
        if (pts == null || pts.size < 2) return speedCurve
        val a0 = o.inPoint; val len0 = o.outPoint - o.inPoint
        val a1 = inPoint; val len1 = outPoint - inPoint
        if (len0 <= 1e-6 || len1 <= 1e-6) return o.speedCurve
        val eps = 1e-4
        fun u(src: Double) = (src - a1) / len1
        fun old(src: Double) = SpeedCurve.value(pts, ((src - a0) / len0).coerceIn(0.0, 1.0))
        val headAdded = u(a0) > eps
        val tailAdded = u(a0 + len0) < 1 - eps
        val out = mutableListOf(SpeedPoint(0.0, if (headAdded) 1.0 else old(a1)))
        for (p in pts) {
            val t = u(a0 + p.t * len0)
            if (t > eps && t < 1 - eps && t - out[out.size - 1].t > 0.002) out.add(SpeedPoint(t, p.v))
        }
        out.add(SpeedPoint(1.0, if (tailAdded) 1.0 else old(a1 + len1)))
        return out
    }

    /** Part of the curve between u0 and u1, renormalized to 0...1 (used by split). */
    fun subCurve(u0: Double, u1: Double): List<SpeedPoint>? {
        val pts = speedCurve
        if (pts == null || pts.size < 2 || u1 - u0 <= 1e-6) return speedCurve
        val out = mutableListOf(SpeedPoint(0.0, SpeedCurve.value(pts, u0)))
        for (p in pts) if (p.t > u0 + 1e-6 && p.t < u1 - 1e-6) out.add(SpeedPoint((p.t - u0) / (u1 - u0), p.v))
        out.add(SpeedPoint(1.0, SpeedCurve.value(pts, u1)))
        return out
    }

    fun baseFraction(canvasAspect: Double): Pair<Double, Double> = baseFraction(aspect ?: canvasAspect, fill, canvasAspect)

    val speedLabel: String?
        get() = if (hasCurve) "curve" else if (abs(speed - 1) < 0.001) null else Fmt.speed(speed)

    /** Swap to the reversed copy at `file` (covering inPoint...outPoint of the current file, `length` long). */
    fun reversing(file: String, length: Double) = copy(
        reversed = ReverseOrigin(mediaFile, sourceDuration, inPoint, outPoint),
        mediaFile = file, sourceDuration = length, inPoint = 0.0, outPoint = minOf(length, outPoint - inPoint),
        speedCurve = mirrored(speedCurve), keyframes = mirrored(keyframes, outPoint),
        stabilization = null, tracking = null,
    )

    /** Back to the original file, keeping any trims made while reversed. */
    fun unreversed(): Clip {
        val o = reversed ?: return this
        return copy(mediaFile = o.mediaFile, sourceDuration = o.sourceDuration,
            inPoint = maxOf(0.0, o.outPoint - outPoint), outPoint = minOf(o.sourceDuration, o.outPoint - inPoint),
            speedCurve = mirrored(speedCurve), keyframes = mirrored(keyframes, o.outPoint), reversed = null)
    }

    companion object {
        /** A new clip of a whole file (Swift's `init(mediaFile:sourceDuration:)`). */
        fun new(mediaFile: String, sourceDuration: Double) =
            Clip(mediaFile = mediaFile, sourceDuration = sourceDuration, pitchCorrect = Defaults.keepPitch)

        /** Size of the clip on the canvas before its transform, as fractions of canvas width and height. */
        fun baseFraction(aspect: Double, fill: Boolean, canvasAspect: Double): Pair<Double, Double> {
            val r = maxOf(aspect, 0.0001) / maxOf(canvasAspect, 0.0001)
            return if (fill) maxOf(1.0, r) to maxOf(1.0, 1 / r) else minOf(1.0, r) to minOf(1.0, 1 / r)
        }

        fun mirrored(pts: List<SpeedPoint>?): List<SpeedPoint>? = pts?.reversed()?.map { SpeedPoint(1 - it.t, it.v) }

        /** Keyframes on the other time axis (source time s becomes `pivot - s`); easing stays with its stretch. */
        fun mirrored(keys: List<Keyframe>, pivot: Double): List<Keyframe> {
            val flipped = keys.map { it.copy(t = pivot - it.t) }.sortedBy { it.t }
            return flipped.map { k ->
                val j = keys.indexOfFirst { it.id == k.id }
                if (j > 0) k.copy(ease = keys[j - 1].ease) else k
            }
        }
    }
}

/**
 * Swift's `Clip.init(from:)` fix-ups, done on the JSON before decoding: outPoint defaults to the whole file,
 * motion blur moves out of the Adjust effects (old projects), and it's on when an old project had an amount.
 */
object ClipSerializer : kotlinx.serialization.json.JsonTransformingSerializer<Clip>(Clip.generatedSerializer()) {
    override fun transformDeserialize(element: kotlinx.serialization.json.JsonElement): kotlinx.serialization.json.JsonElement {
        val o = element as? kotlinx.serialization.json.JsonObject ?: return element
        val m = o.toMutableMap()
        fun num(e: kotlinx.serialization.json.JsonElement?): Double? =
            (e as? kotlinx.serialization.json.JsonPrimitive)?.content?.toDoubleOrNull()
        fun effectsBlur(e: kotlinx.serialization.json.JsonElement?): Double =
            num((e as? kotlinx.serialization.json.JsonObject)?.get("motionBlur")) ?: 0.0
        fun withoutBlur(e: kotlinx.serialization.json.JsonElement?): kotlinx.serialization.json.JsonElement? {
            val eo = e as? kotlinx.serialization.json.JsonObject ?: return e
            return kotlinx.serialization.json.JsonObject(eo + ("motionBlur" to kotlinx.serialization.json.JsonPrimitive(0.0)))
        }
        if (!m.containsKey("outPoint")) m["sourceDuration"]?.let { m["outPoint"] = it }
        var blur = num(m["motionBlur"]) ?: 0.0
        val keys = (m["keyframes"] as? kotlinx.serialization.json.JsonArray) ?: kotlinx.serialization.json.JsonArray(emptyList())
        if (blur == 0.0) {
            blur = maxOf(effectsBlur(m["effects"]),
                keys.maxOfOrNull { effectsBlur((it as? kotlinx.serialization.json.JsonObject)?.get("look")?.let { l -> (l as? kotlinx.serialization.json.JsonObject)?.get("effects") }) } ?: 0.0)
        }
        if (m.containsKey("effects")) m["effects"] = withoutBlur(m["effects"])!!
        if (m.containsKey("keyframes")) m["keyframes"] = kotlinx.serialization.json.JsonArray(keys.map { k ->
            val ko = k as? kotlinx.serialization.json.JsonObject ?: return@map k
            val look = ko["look"] as? kotlinx.serialization.json.JsonObject ?: return@map k
            kotlinx.serialization.json.JsonObject(ko + ("look" to kotlinx.serialization.json.JsonObject(look + ("effects" to (withoutBlur(look["effects"]) ?: kotlinx.serialization.json.JsonObject(emptyMap()))))))
        })
        val savedOn = (m["motionBlurOn"] as? kotlinx.serialization.json.JsonPrimitive)?.content?.toBooleanStrictOrNull()
        m["motionBlurOn"] = kotlinx.serialization.json.JsonPrimitive(savedOn ?: (blur > 0.001))
        m["motionBlur"] = kotlinx.serialization.json.JsonPrimitive(if (blur < 0.001) 0.5 else blur)
        return kotlinx.serialization.json.JsonObject(m)
    }
}
