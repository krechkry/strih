// Ported from Bombocut/Model/Look.swift (iOS ad3827a).
// Swift's custom init(from:) fix-ups live in surrogate serializers here (same keys, same defaults, same upgrades).
@file:Suppress("EnumEntryName")
package cz.krechler.bombocut.model

import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import java.util.UUID
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.ln
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.sqrt

/** Color + finishing effects for a clip. Every field is keyframable. */
@Serializable(with = EffectsSerializer::class)
data class Effects(
    val exposure: Double = 0.0,      // -1...1  (±2 EV)
    val contrast: Double = 0.0,
    val saturation: Double = 0.0,
    val temperature: Double = 0.0,   // cool ... warm
    val tint: Double = 0.0,          // green ... magenta
    val highlights: Double = 0.0,
    val shadows: Double = 0.0,
    val vignette: Double = 0.0,      // 0...1
    val aberration: Double = 0.0,    // 0...1 chromatic aberration
    val grain: Double = 0.0,
    val grainSize: Double = 0.4,
    val bloom: Double = 0.0,
    val bloomSize: Double = 0.4,
    val bloomThreshold: Double = 0.0,
    val halation: Double = 0.0,
    val halationSize: Double = 0.4,
    val halationThreshold: Double = 0.5,
    val clarity: Double = 0.0,
    val texture: Double = 0.0,
    val motionBlur: Double = 0.0,    // old projects only: motion blur lives on the clip now
    val curve: List<Double> = flatCurve,
    val curveR: List<Double> = flatCurve,
    val curveG: List<Double> = flatCurve,
    val curveB: List<Double> = flatCurve,
    val hslHue: List<Double> = flatHSL,
    val hslSat: List<Double> = flatHSL,
    val hslLum: List<Double> = flatHSL,
) {
    val hasCurves: Boolean get() = curve != flatCurve || curveR != flatCurve || curveG != flatCurve || curveB != flatCurve
    val hasHSL: Boolean get() = hslHue != flatHSL || hslSat != flatHSL || hslLum != flatHSL
    val hasColor: Boolean
        get() = exposure != 0.0 || contrast != 0.0 || saturation != 0.0 || temperature != 0.0 || tint != 0.0 ||
            highlights != 0.0 || shadows != 0.0 || hasCurves || hasHSL
    val hasCanvasFX: Boolean
        get() = vignette > 0 || aberration > 0 || grain > 0 || bloom > 0 || halation > 0 || clarity != 0.0 || texture != 0.0

    companion object {
        val flatCurve = listOf(0.0, 0.0, 1.0, 1.0)
        val flatHSL = List(8) { 0.0 }

        fun lerp(a: Effects, b: Effects, f: Double): Effects {
            fun m(x: Double, y: Double) = x + (y - x) * f
            fun ms(x: List<Double>, y: List<Double>): List<Double> =
                if (x.size != y.size) (if (f < 0.5) x else y) else x.zip(y) { p, q -> m(p, q) }
            return Effects(
                exposure = m(a.exposure, b.exposure), contrast = m(a.contrast, b.contrast),
                saturation = m(a.saturation, b.saturation), temperature = m(a.temperature, b.temperature),
                tint = m(a.tint, b.tint), highlights = m(a.highlights, b.highlights), shadows = m(a.shadows, b.shadows),
                vignette = m(a.vignette, b.vignette), aberration = m(a.aberration, b.aberration),
                grain = m(a.grain, b.grain), grainSize = m(a.grainSize, b.grainSize),
                bloom = m(a.bloom, b.bloom), bloomSize = m(a.bloomSize, b.bloomSize),
                bloomThreshold = m(a.bloomThreshold, b.bloomThreshold),
                halation = m(a.halation, b.halation), halationSize = m(a.halationSize, b.halationSize),
                halationThreshold = m(a.halationThreshold, b.halationThreshold),
                clarity = m(a.clarity, b.clarity), texture = m(a.texture, b.texture),
                // Swift's lerp starts from Effects(), so motionBlur is 0
                curve = ms(a.curve, b.curve), curveR = ms(a.curveR, b.curveR), curveG = ms(a.curveG, b.curveG),
                curveB = ms(a.curveB, b.curveB),
                hslHue = ms(a.hslHue, b.hslHue), hslSat = ms(a.hslSat, b.hslSat), hslLum = ms(a.hslLum, b.hslLum),
            )
        }
    }
}

/** Effects as stored: every key optional; curves and HSL checked and upgraded like Swift's init(from:). */
@Serializable
private data class EffectsStored(
    val exposure: Double? = null, val contrast: Double? = null, val saturation: Double? = null,
    val temperature: Double? = null, val tint: Double? = null, val highlights: Double? = null,
    val shadows: Double? = null, val vignette: Double? = null, val aberration: Double? = null,
    val grain: Double? = null, val grainSize: Double? = null, val motionBlur: Double? = null,
    val bloom: Double? = null, val bloomSize: Double? = null, val bloomThreshold: Double? = null,
    val halation: Double? = null, val halationSize: Double? = null, val halationThreshold: Double? = null,
    val clarity: Double? = null, val texture: Double? = null,
    val curve: List<Double>? = null, val curveR: List<Double>? = null, val curveG: List<Double>? = null,
    val curveB: List<Double>? = null, val hslHue: List<Double>? = null, val hslSat: List<Double>? = null,
    val hslLum: List<Double>? = null,
)

object EffectsSerializer : KSerializer<Effects> {
    private val stored = EffectsStored.serializer()
    override val descriptor: SerialDescriptor = stored.descriptor

    private fun curveArr(a: List<Double>?): List<Double> {
        if (a == null) return Effects.flatCurve
        if (a == listOf(0.0, 0.25, 0.5, 0.75, 1.0)) return Effects.flatCurve   // the old straight line
        if (a.size == 5) return ToneCurve.upgraded(a)
        return if (a.size >= 4 && a.size % 2 == 0) a else Effects.flatCurve
    }
    private fun arr(a: List<Double>?, def: List<Double>) = if (a != null && a.size == def.size) a else def

    override fun deserialize(decoder: Decoder): Effects {
        val s = decoder.decodeSerializableValue(stored)
        return Effects(
            exposure = s.exposure ?: 0.0, contrast = s.contrast ?: 0.0, saturation = s.saturation ?: 0.0,
            temperature = s.temperature ?: 0.0, tint = s.tint ?: 0.0, highlights = s.highlights ?: 0.0,
            shadows = s.shadows ?: 0.0, vignette = s.vignette ?: 0.0, aberration = s.aberration ?: 0.0,
            grain = s.grain ?: 0.0, grainSize = s.grainSize ?: 0.4, motionBlur = s.motionBlur ?: 0.0,
            bloom = s.bloom ?: 0.0, bloomSize = s.bloomSize ?: 0.4, bloomThreshold = s.bloomThreshold ?: 0.0,
            halation = s.halation ?: 0.0, halationSize = s.halationSize ?: 0.4,
            halationThreshold = s.halationThreshold ?: 0.5, clarity = s.clarity ?: 0.0, texture = s.texture ?: 0.0,
            curve = curveArr(s.curve), curveR = curveArr(s.curveR), curveG = curveArr(s.curveG), curveB = curveArr(s.curveB),
            hslHue = arr(s.hslHue, Effects.flatHSL), hslSat = arr(s.hslSat, Effects.flatHSL), hslLum = arr(s.hslLum, Effects.flatHSL),
        )
    }

    override fun serialize(encoder: Encoder, value: Effects) {
        val v = value
        encoder.encodeSerializableValue(stored, EffectsStored(
            v.exposure, v.contrast, v.saturation, v.temperature, v.tint, v.highlights, v.shadows, v.vignette,
            v.aberration, v.grain, v.grainSize, v.motionBlur, v.bloom, v.bloomSize, v.bloomThreshold, v.halation,
            v.halationSize, v.halationThreshold, v.clarity, v.texture, v.curve, v.curveR, v.curveG, v.curveB,
            v.hslHue, v.hslSat, v.hslLum))
    }
}

/** Everything about how a clip looks at one moment: placement, opacity, effects. */
@Serializable
data class Look(
    val transform: ClipTransform = ClipTransform(),
    val opacity: Double = 1.0,
    val effects: Effects = Effects(),
) {
    companion object {
        fun lerp(a: Look, b: Look, f: Double): Look {
            // zoom feels even when interpolated in log space
            val s0 = maxOf(a.transform.scale, 0.001)
            val s1 = maxOf(b.transform.scale, 0.001)
            return Look(
                transform = ClipTransform(
                    x = a.transform.x + (b.transform.x - a.transform.x) * f,
                    y = a.transform.y + (b.transform.y - a.transform.y) * f,
                    scale = exp(ln(s0) + (ln(s1) - ln(s0)) * f),
                    rotation = a.transform.rotation + (b.transform.rotation - a.transform.rotation) * f,
                ),
                opacity = a.opacity + (b.opacity - a.opacity) * f,
                effects = Effects.lerp(a.effects, b.effects, f),
            )
        }
    }
}

/** The Adjust panel's tabs; each one's reset only puts back what that tab shows. */
enum class LookTab {
    basic, advanced, effects;

    fun reset(l: Look): Look = when (this) {
        basic -> LookParam.basic.fold(l) { acc, p -> p.set(acc, p.neutral) }
        advanced -> l.copy(effects = l.effects.copy(
            curve = Effects.flatCurve, curveR = Effects.flatCurve, curveG = Effects.flatCurve, curveB = Effects.flatCurve,
            hslHue = Effects.flatHSL, hslSat = Effects.flatHSL, hslLum = Effects.flatHSL))
        effects -> (LookParam.effects + LookParam.effects.flatMap { it.subParams }).fold(l) { acc, p -> p.set(acc, p.neutral) }
    }
}

/** How a change speeds up and slows down between two keyframes. "Ease" (smooth) is the usual one. */
@Serializable
enum class Ease {
    linear, smooth, quad, bezier;

    val title: String get() = when (this) { linear -> "Linear"; smooth -> "Ease"; quad -> "Quad"; bezier -> "Bezier" }

    /** Progress 0...1 shaped by the curve: slow at the start (in), at the end (out) or both. */
    fun apply(f0: Double, dir: EaseDir = EaseDir.both): Double {
        val f = f0.coerceIn(0.0, 1.0)
        return when (this) {
            linear -> f
            smooth -> when (dir) {
                EaseDir.both -> f * f * (3 - 2 * f)
                EaseDir.`in` -> 1 - cos(f * PI / 2)
                EaseDir.out -> sin(f * PI / 2)
            }
            quad -> when (dir) {
                EaseDir.both -> if (f < 0.5) 2 * f * f else 1 - (-2 * f + 2).pow(2) / 2
                EaseDir.`in` -> f * f
                EaseDir.out -> 1 - (1 - f) * (1 - f)
            }
            bezier -> when (dir) {
                EaseDir.both -> cubicBezier(f, 0.65, 0.0, 0.35, 1.0)
                EaseDir.`in` -> cubicBezier(f, 0.6, 0.0, 0.9, 0.45)
                EaseDir.out -> cubicBezier(f, 0.1, 0.55, 0.4, 1.0)
            }
        }
    }

    companion object {
        /** CSS-style cubic Bézier from (0, 0) to (1, 1): y for a given x. */
        fun cubicBezier(x: Double, x1: Double, y1: Double, x2: Double, y2: Double): Double {
            fun bx(t: Double) = 3 * (1 - t) * (1 - t) * t * x1 + 3 * (1 - t) * t * t * x2 + t * t * t
            fun by(t: Double) = 3 * (1 - t) * (1 - t) * t * y1 + 3 * (1 - t) * t * t * y2 + t * t * t
            var lo = 0.0; var hi = 1.0; var t = x
            repeat(24) {
                t = (lo + hi) / 2
                if (bx(t) < x) lo = t else hi = t
            }
            return by(t)
        }
    }
}

/** Where the easing slows the change: at the start, at the end, or both. */
@Serializable
enum class EaseDir {
    `in`, out, both;
    val title: String get() = when (this) { `in` -> "In"; out -> "Out"; both -> "Both" }
}

@Serializable
data class Keyframe(
    @Serializable(with = UUIDSerializer::class) val id: UUID = UUID.randomUUID(),
    val t: Double,                 // source time in seconds
    val look: Look,
    val ease: Ease = Ease.smooth,  // easing towards the next keyframe
    val easeDir: EaseDir? = null,  // nil = both
)

/** Look at a source time from a static look and keyframes (the compositor's LookState has more, see Motion.kt). */
fun lookAt(look: Look, keyframes: List<Keyframe>, s: Double): Look {
    val first = keyframes.firstOrNull() ?: return look
    if (keyframes.size == 1 || s <= first.t) return first.look
    val last = keyframes[keyframes.size - 1]
    if (s >= last.t) return last.look
    var i = 0
    while (i < keyframes.size - 2 && s > keyframes[i + 1].t) i += 1
    val a = keyframes[i]
    val b = keyframes[i + 1]
    var f = ((s - a.t) / maxOf(b.t - a.t, 1e-9)).coerceIn(0.0, 1.0)
    f = a.ease.apply(f, a.easeDir ?: EaseDir.both)
    return Look.lerp(a.look, b.look, f)
}

/** The sliders in the Adjust sheet. */
enum class LookParam {
    exposure, contrast, saturation, temperature, tint, highlights, shadows,
    vignette, aberration, grain, grainSize, opacity, bloom, halation, clarity, texture, bloomSize, bloomThreshold,
    halationSize, halationThreshold;

    val subParams: List<LookParam>
        get() = when (this) {
            bloom -> listOf(bloomSize, bloomThreshold)
            halation -> listOf(halationSize, halationThreshold)
            grain -> listOf(grainSize)
            else -> emptyList()
        }

    val subTitle: String
        get() = when (this) {
            bloomSize, grainSize -> "Size"
            bloomThreshold, halationThreshold -> "Threshold"
            halationSize -> "Radius"
            else -> title
        }

    val title: String
        get() = when (this) {
            exposure -> "Exposure"; contrast -> "Contrast"; saturation -> "Saturation"; temperature -> "Temp"
            tint -> "Tint"; highlights -> "Highlights"; shadows -> "Shadows"; vignette -> "Vignette"
            aberration -> "Chroma"; grain -> "Grain"; grainSize -> "Grain size"; opacity -> "Opacity"
            bloom -> "Bloom"; bloomSize -> "Bloom size"; bloomThreshold -> "Bloom threshold"
            halation -> "Halation"; halationSize -> "Halation radius"; halationThreshold -> "Halation threshold"
            clarity -> "Clarity"; texture -> "Texture"
        }

    val range: ClosedFloatingPointRange<Double>
        get() = when (this) {
            vignette, aberration, grain, grainSize, opacity, bloom, halation, bloomSize, bloomThreshold,
            halationSize, halationThreshold -> 0.0..1.0
            else -> -1.0..1.0
        }

    val neutral: Double
        get() = when (this) {
            opacity -> 1.0
            grainSize, bloomSize, halationSize -> 0.4
            halationThreshold -> 0.5
            else -> 0.0
        }

    fun get(l: Look): Double = when (this) {
        exposure -> l.effects.exposure; contrast -> l.effects.contrast; saturation -> l.effects.saturation
        temperature -> l.effects.temperature; tint -> l.effects.tint; highlights -> l.effects.highlights
        shadows -> l.effects.shadows; vignette -> l.effects.vignette; aberration -> l.effects.aberration
        grain -> l.effects.grain; grainSize -> l.effects.grainSize; opacity -> l.opacity
        bloom -> l.effects.bloom; bloomSize -> l.effects.bloomSize; bloomThreshold -> l.effects.bloomThreshold
        halation -> l.effects.halation; halationSize -> l.effects.halationSize
        halationThreshold -> l.effects.halationThreshold; clarity -> l.effects.clarity; texture -> l.effects.texture
    }

    /** Swift's `set(_ l: inout Look, _ v:)`, returning the changed look. */
    fun set(l: Look, value: Double): Look {
        val v = value.coerceIn(range.start, range.endInclusive)
        val e = l.effects
        return when (this) {
            opacity -> l.copy(opacity = v)
            else -> l.copy(effects = when (this) {
                exposure -> e.copy(exposure = v); contrast -> e.copy(contrast = v); saturation -> e.copy(saturation = v)
                temperature -> e.copy(temperature = v); tint -> e.copy(tint = v); highlights -> e.copy(highlights = v)
                shadows -> e.copy(shadows = v); vignette -> e.copy(vignette = v); aberration -> e.copy(aberration = v)
                grain -> e.copy(grain = v); grainSize -> e.copy(grainSize = v); bloom -> e.copy(bloom = v)
                bloomSize -> e.copy(bloomSize = v); bloomThreshold -> e.copy(bloomThreshold = v)
                halation -> e.copy(halation = v); halationSize -> e.copy(halationSize = v)
                halationThreshold -> e.copy(halationThreshold = v); clarity -> e.copy(clarity = v)
                texture -> e.copy(texture = v); opacity -> e
            })
        }
    }

    /** "+35", "-20", "80" */
    fun display(v: Double): String {
        val n = swiftRound(v * 100)
        return if (range.start < 0 && n > 0) "+$n" else "$n"
    }

    companion object {
        val basic = listOf(exposure, contrast, saturation, temperature, tint, highlights, shadows, opacity)
        val effects = listOf(clarity, texture, bloom, halation, vignette, aberration, grain)
    }
}

/** Which neighbouring frames motion blur smears towards. */
@Serializable
enum class BlurDirection {
    both, forward, backward;
    val title: String get() = when (this) { both -> "Both ways"; forward -> "Forward"; backward -> "Backward" }
}

/** The color bands of the HSL editor (hue centers in degrees). */
enum class HSLBand {
    red, orange, yellow, green, aqua, blue, purple, magenta;
    val hue: Double get() = listOf(0.0, 30.0, 60.0, 120.0, 180.0, 225.0, 270.0, 315.0)[ordinal]
    val title: String get() = name.replaceFirstChar { it.uppercase() }
}

/** A tone curve stored flat as x0, y0, x1, y1, … (older projects: five heights at 0, ¼, ½, ¾, 1). */
object ToneCurve {
    fun points(c: List<Double>): List<Pair<Double, Double>> {
        if (c.size == 5) return listOf(0.0, 0.25, 0.5, 0.75, 1.0).zip(c)
        if (c.size < 4 || c.size % 2 != 0) return listOf(0.0 to 0.0, 1.0 to 1.0)
        return (c.indices step 2).map { c[it] to c[it + 1] }
    }

    fun flat(p: List<Pair<Double, Double>>): List<Double> = p.flatMap { listOf(it.first, it.second) }

    fun upgraded(c: List<Double>): List<Double> = if (c.size == 5) flat(points(c)) else c

    /** Smooth curve through the points without overshoot (monotone cubic); flat outside. */
    fun value(c: List<Double>, x0: Double): Double {
        val p = points(c)
        val n = p.size
        val x = x0.coerceIn(0.0, 1.0)
        if (x <= p[0].first) return p[0].second.coerceIn(0.0, 1.0)
        if (x >= p[n - 1].first) return p[n - 1].second.coerceIn(0.0, 1.0)
        val d = DoubleArray(n - 1)
        for (i in 0 until n - 1) {
            val h = p[i + 1].first - p[i].first
            d[i] = if (h > 1e-9) (p[i + 1].second - p[i].second) / h else 0.0
        }
        val m = DoubleArray(n)
        m[0] = d[0]
        m[n - 1] = d[n - 2]
        if (n > 2) for (i in 1 until n - 1) m[i] = if (d[i - 1] * d[i] <= 0) 0.0 else (d[i - 1] + d[i]) / 2
        for (i in 0 until n - 1) {
            if (abs(d[i]) < 1e-12) { m[i] = 0.0; m[i + 1] = 0.0; continue }
            val a = m[i] / d[i]
            val b = m[i + 1] / d[i]
            val s = a * a + b * b
            if (s > 9) { val t = 3 / sqrt(s); m[i] = t * a * d[i]; m[i + 1] = t * b * d[i] }
        }
        var k = 0
        while (k < n - 2 && x > p[k + 1].first) k += 1
        val h = p[k + 1].first - p[k].first
        if (h <= 1e-9) return p[k + 1].second
        val t = (x - p[k].first) / h
        val t2 = t * t
        val t3 = t2 * t
        val y = (2 * t3 - 3 * t2 + 1) * p[k].second + (t3 - 2 * t2 + t) * h * m[k] +
            (-2 * t3 + 3 * t2) * p[k + 1].second + (t3 - t2) * h * m[k + 1]
        return y.coerceIn(0.0, 1.0)
    }
}

/** AutoZoom: the clip slowly zooms from its first frame to its last (two keyframes on the clip's ends). */
@Serializable(with = AutoZoomSerializer::class)
data class AutoZoom(
    val start: Framing = Framing(),
    val end: Framing = Framing(zoom = 1.2),
    val ease: Ease = Ease.linear,
    val easeDir: EaseDir? = null,
) {
    /** How close (1 = the clip as placed) and where the view is centered (canvas fractions from the middle). */
    @Serializable
    data class Framing(val zoom: Double = 1.0, val x: Double = 0.0, val y: Double = 0.0)

    fun framing(p: Double): Framing {
        val f = ease.apply(p.coerceIn(0.0, 1.0), easeDir ?: EaseDir.both)
        val z0 = maxOf(start.zoom, 0.05)
        val z1 = maxOf(end.zoom, 0.05)
        return Framing(exp(ln(z0) + (ln(z1) - ln(z0)) * f), start.x + (end.x - start.x) * f, start.y + (end.y - start.y) * f)
    }

    fun halves(p: Double): Pair<AutoZoom, AutoZoom> { val m = framing(p); return copy(end = m) to copy(start = m) }

    fun apply(t: ClipTransform, p: Double): ClipTransform {
        val f = framing(p)
        return t.copy(scale = t.scale * f.zoom, x = t.x - f.zoom * f.x, y = t.y - f.zoom * f.y)
    }
}

@Serializable
private data class AutoZoomStored(
    val start: AutoZoom.Framing? = null, val end: AutoZoom.Framing? = null,
    val ease: Ease? = null, val easeDir: EaseDir? = null,
    // earlier projects
    val zoomIn: Boolean? = null, val amount: Double? = null, val focusX: Double? = null, val focusY: Double? = null,
)

object AutoZoomSerializer : KSerializer<AutoZoom> {
    private val stored = AutoZoomStored.serializer()
    override val descriptor: SerialDescriptor = stored.descriptor

    override fun deserialize(decoder: Decoder): AutoZoom {
        val s = decoder.decodeSerializableValue(stored)
        val ease = s.ease ?: Ease.linear
        if (s.start != null && s.end != null) return AutoZoom(s.start, s.end, ease, s.easeDir)
        val zoomIn = s.zoomIn ?: true
        val z = 1 + (s.amount ?: 0.2)
        val tight = AutoZoom.Framing(z, (s.focusX ?: 0.0) * (1 - 1 / z), (s.focusY ?: 0.0) * (1 - 1 / z))
        return AutoZoom(if (zoomIn) AutoZoom.Framing() else tight, if (zoomIn) tight else AutoZoom.Framing(), ease, s.easeDir)
    }

    override fun serialize(encoder: Encoder, value: AutoZoom) =
        encoder.encodeSerializableValue(stored, AutoZoomStored(value.start, value.end, value.ease, value.easeDir))
}

/** Crop of a clip's own picture: sides, soft edge, rounded corners, or an ellipse / drawn curve; plus mirror. */
@Serializable
data class CropRect(
    val left: Double = 0.0,
    val top: Double = 0.0,
    val right: Double = 0.0,
    val bottom: Double = 0.0,
    val softness: Double = 0.0,
    val radius: Double = 0.0,
    val kind: CropKind = CropKind.rect,
    val ellipse: CropEllipse? = null,     // nil: a circle in the middle
    val points: List<CropPoint> = emptyList(),
    val feather: Double = 0.0,
    val invert: Boolean = false,
    val flipX: Boolean = false,
    val flipY: Boolean = false,
) {
    val mirrored: Boolean get() = flipX || flipY
    val flipScale: Pair<Double, Double> get() = (if (flipX) -1.0 else 1.0) to (if (flipY) -1.0 else 1.0)
    val isEmpty: Boolean get() = keepsAll && !mirrored
    val keepsAll: Boolean
        get() = when (kind) {
            CropKind.rect -> left < 0.0005 && top < 0.0005 && right < 0.0005 && bottom < 0.0005 && softness < 0.001 && radius < 0.001
            CropKind.ellipse -> false
            CropKind.curve -> points.size < 3
        }

    /** The kept part, normalized, top-left origin: x, y, width, height. */
    val rect: List<Double> get() = listOf(left, top, maxOf(0.01, 1 - left - right), maxOf(0.01, 1 - top - bottom))

    fun ellipse(aspect: Double): CropEllipse {
        ellipse?.let { return it }
        val a = maxOf(aspect, 0.01)
        return if (a >= 1) CropEllipse(rx = 0.3 / a, ry = 0.3) else CropEllipse(rx = 0.3, ry = 0.3 * a)
    }
}

@Serializable enum class CropKind { rect, ellipse, curve }

@Serializable data class CropEllipse(val cx: Double = 0.5, val cy: Double = 0.5, val rx: Double = 0.3, val ry: Double = 0.3)

@Serializable data class CropPoint(val x: Double, val y: Double)
