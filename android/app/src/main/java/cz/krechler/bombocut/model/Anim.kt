// Ported from Bombocut/Model/Anim.swift (iOS ad3827a).
@file:Suppress("EnumEntryName")
package cz.krechler.bombocut.model

import kotlinx.serialization.Serializable
import kotlin.math.abs
import kotlin.math.ln
import kotlin.math.pow

/** Basic in / out animations for text, overlays and clips. */
@Serializable
enum class MotionAnim {
    none, fade, slideUp, slideDown, slideLeft, slideRight, pop, zoomIn, zoomOut,
    smooth;          // between clips only: the cut is morphed away (similar footage, no jump)

    val title: String
        get() = when (this) {
            none -> "None"; fade -> "Fade"; slideUp -> "Slide up"; slideDown -> "Slide down"
            slideLeft -> "Slide left"; slideRight -> "Slide right"; pop -> "Pop"
            zoomIn -> "Zoom in"; zoomOut -> "Zoom out"; smooth -> "Smooth cut"
        }

    companion object {
        /** In / out animations of text, overlays and clips. */
        val animations = listOf(none, fade, slideUp, slideDown, slideLeft, slideRight, pop, zoomIn, zoomOut)
        /** Transitions between two clips, in the order they are offered. */
        val transitions = listOf(none, fade, smooth, zoomIn, zoomOut, slideLeft, slideRight, slideUp, slideDown, pop)
    }
}

/** Offset (fractions of the canvas, + = right / down), scale and opacity. */
data class Pose(val dx: Double = 0.0, val dy: Double = 0.0, val scale: Double = 1.0, val opacity: Double = 1.0)

/** An animation in and an animation out, with their lengths. */
@Serializable
data class AnimPair(
    val inAnim: MotionAnim = MotionAnim.none,
    val outAnim: MotionAnim = MotionAnim.none,
    val inDur: Double = 0.4,
    val outDur: Double = 0.4,
) {
    /** Only fades kept (adjustment layers have no picture to slide or zoom). */
    val fadesOnly: AnimPair
        get() = copy(inAnim = if (inAnim != MotionAnim.none) MotionAnim.fade else MotionAnim.none,
                     outAnim = if (outAnim != MotionAnim.none) MotionAnim.fade else MotionAnim.none)

    val isNone: Boolean get() = inAnim == MotionAnim.none && outAnim == MotionAnim.none

    /** Extra offset, scale and opacity `t` seconds into something that lasts `length` seconds. */
    fun pose(t: Double, length: Double): Pose {
        var dx = 0.0; var dy = 0.0; var scale = 1.0; var opacity = 1.0
        fun ease(p: Double) = 1 - (1 - p.coerceIn(0.0, 1.0)).pow(3)
        fun apply(a: MotionAnim, p: Double, exiting: Boolean) {
            if (p >= 1) return
            val e = ease(p)
            val sign = if (exiting) -1.0 else 1.0
            when (a) {
                MotionAnim.none -> {}
                MotionAnim.fade, MotionAnim.smooth -> opacity *= e
                MotionAnim.slideUp -> { dy += sign * 0.12 * (1 - e); opacity *= minOf(1.0, p * 2.5) }
                MotionAnim.slideDown -> { dy -= sign * 0.12 * (1 - e); opacity *= minOf(1.0, p * 2.5) }
                MotionAnim.slideLeft -> { dx += sign * 0.15 * (1 - e); opacity *= minOf(1.0, p * 2.5) }
                MotionAnim.slideRight -> { dx -= sign * 0.15 * (1 - e); opacity *= minOf(1.0, p * 2.5) }
                MotionAnim.pop -> {
                    val q = p.coerceIn(0.0, 1.0)
                    scale *= if (q < 0.7) 0.5 + 0.6 * (q / 0.7) else 1.1 - 0.1 * ((q - 0.7) / 0.3)
                    opacity *= minOf(1.0, q * 3)
                }
                MotionAnim.zoomIn -> { scale *= if (exiting) 1 + 0.4 * (1 - e) else 0.6 + 0.4 * e; opacity *= e }
                MotionAnim.zoomOut -> { scale *= if (exiting) 0.6 + 0.4 * e else 1.4 - 0.4 * e; opacity *= e }
            }
        }
        val inLen = minOf(inDur, length / 2)
        val outLen = minOf(outDur, length / 2)
        if (inAnim != MotionAnim.none && inLen > 0.001) apply(inAnim, t / inLen, exiting = false)
        if (outAnim != MotionAnim.none && outLen > 0.001) apply(outAnim, (length - t) / outLen, exiting = true)
        return Pose(dx, dy, scale, maxOf(0.0, opacity))
    }
}

/** A transition between two clips (see Anim.swift and `Project.cutShape`). */
@Serializable
data class CutTransition(
    val kind: MotionAnim = MotionAnim.fade,
    val duration: Double = 0.5,
    /** Uses the footage past the clips' ends. Nil in projects made before this. */
    val handles: Boolean? = true,
) {
    /** Both clips `t` seconds into an overlap of `length` seconds: going out, coming in (drawn on top). */
    fun poses(t: Double, length: Double): Pair<Pose, Pose> {
        val p = (t / maxOf(length, 1e-6)).coerceIn(0.0, 1.0)
        val e = p * p * (3 - 2 * p)
        var o = Pose()
        var i = Pose()
        val zoom = 1.6
        when (kind) {
            MotionAnim.none -> i = i.copy(opacity = if (p < 0.5) 0.0 else 1.0)
            MotionAnim.fade, MotionAnim.smooth -> i = i.copy(opacity = e)
            MotionAnim.slideLeft -> { i = i.copy(dx = 1 - e); o = o.copy(dx = -e) }
            MotionAnim.slideRight -> { i = i.copy(dx = -(1 - e)); o = o.copy(dx = e) }
            MotionAnim.slideUp -> { i = i.copy(dy = 1 - e); o = o.copy(dy = -e) }
            MotionAnim.slideDown -> { i = i.copy(dy = -(1 - e)); o = o.copy(dy = e) }
            MotionAnim.zoomIn, MotionAnim.zoomOut -> {
                val dir = if (kind == MotionAnim.zoomIn) 1.0 else -1.0
                if (p < 0.5) {
                    val q = p / 0.5
                    o = o.copy(scale = zoom.pow(dir * q * q))
                    i = i.copy(opacity = 0.0)
                } else {
                    val left = 1 - (p - 0.5) / 0.5
                    i = i.copy(scale = zoom.pow(-dir * left * left))
                    o = o.copy(opacity = 0.0)
                }
            }
            MotionAnim.pop -> {
                o = o.copy(scale = 1 - 0.1 * e)
                i = i.copy(scale = if (p < 0.7) 0.5 + 0.6 * (p / 0.7) else 1.1 - 0.1 * ((p - 0.7) / 0.3),
                           opacity = minOf(1.0, p * 3))
            }
        }
        return o to i
    }

    /** How fast the picture moves at time t (for motion blur): dx, dy per second and the zoom speed. */
    fun motion(t: Double, length: Double): Triple<Double, Double, Double> {
        when (kind) {
            MotionAnim.slideLeft, MotionAnim.slideRight, MotionAnim.slideUp, MotionAnim.slideDown,
            MotionAnim.zoomIn, MotionAnim.zoomOut -> {}
            else -> return Triple(0.0, 0.0, 0.0)
        }
        val h = maxOf(length, 1e-3) / 200
        fun shown(at: Double): Pose { val (o, i) = poses(at, length); return if (i.opacity >= 0.5) i else o }
        val a = shown(maxOf(0.0, t - h))
        val b = shown(minOf(length, t + h))
        val dt = minOf(length, t + h) - maxOf(0.0, t - h)
        if (dt <= 0) return Triple(0.0, 0.0, 0.0)
        var dz = (ln(b.scale) - ln(a.scale)) / dt
        if (abs(dz) > 50) dz = 0.0
        return Triple((b.dx - a.dx) / dt, (b.dy - a.dy) / dt, dz)
    }
}
