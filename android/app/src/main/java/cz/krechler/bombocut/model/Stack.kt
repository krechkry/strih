// Ported from Bombocut/Model/Stack.swift (iOS ad3827a).
package cz.krechler.bombocut.model

import kotlinx.serialization.Serializable
import java.util.UUID
import kotlin.math.abs

/** A Stack: neighbouring clips held together and treated as one, with a layer of its own on top (Stack time). */
@Serializable
data class ClipStack(
    @Serializable(with = UUIDSerializer::class) val id: UUID = UUID.randomUUID(),
    val clipIDs: List<@Serializable(with = UUIDSerializer::class) UUID> = emptyList(),
    val open: Boolean = false,
    val transform: ClipTransform = ClipTransform(),
    val opacity: Double = 1.0,
    val effects: Effects = Effects(),
    val keyframes: List<Keyframe> = emptyList(),
    val crop: CropRect? = null,
    val autoZoom: AutoZoom? = null,
    val volume: Double = 1.0,
    val filter: LookFilter? = null,
    val anim: AnimPair = AnimPair(),
    val speed: Double = 1.0,
    val mask: SubjectMask? = null,
    val motionBlur: Double = 0.5,
    val motionBlurOn: Boolean = false,
    val blurDirection: BlurDirection = BlurDirection.both,
    val stabilization: Stabilization? = null,
    val tracking: Tracking? = null,
    val fadeIn: Double = 0.0,
    val fadeOut: Double = 0.0,
    val key: ChromaKey? = null,
) {
    val look: Look get() = Look(transform, opacity, effects)
    fun withLook(l: Look) = copy(transform = l.transform, opacity = l.opacity, effects = l.effects)
    fun look(local: Double): Look = lookAt(look, keyframes, local)
    val blurAmount: Double get() = if (motionBlurOn) motionBlur else 0.0

    val hasLayer: Boolean
        get() = !transform.isIdentity || opacity < 0.999 || effects.hasColor || effects.hasCanvasFX ||
            !(crop?.isEmpty ?: true) || autoZoom != null || filter != null || keyframes.isNotEmpty() || !anim.isNone ||
            mask != null || key != null || blurAmount > 0.001 || stabilization != null || (tracking?.let { it.mode != FollowMode.off } ?: false)

    /** Speed as Swift reads it: clamped to 0.05...15. */
    fun normalized() = copy(speed = speed.coerceIn(0.05, 15.0))

    /** Changes the look at Stack time `local`: the fixed look, the keyframe there, or a new keyframe. */
    fun applyLook(local: Double, change: (Look) -> Look): ClipStack {
        if (keyframes.isEmpty()) return withLook(change(look))
        val k = keyframes.indexOfFirst { abs(it.t - local) < 0.025 }
        if (k >= 0) return copy(keyframes = keyframes.toMutableList().also { it[k] = it[k].copy(look = change(it[k].look)) })
        return copy(keyframes = (keyframes + Keyframe(t = local, look = change(look(local)))).sortedBy { it.t })
    }

    fun shiftTime(dt: Double): ClipStack {
        if (abs(dt) <= 1e-9) return this
        return copy(
            keyframes = keyframes.map { it.copy(t = it.t + dt) },
            stabilization = stabilization?.let { st -> st.copy(path = st.path.map { it.copy(t = it.t + dt) }) },
            tracking = tracking?.let { tr -> tr.copy(samples = tr.samples.map { it.copy(t = it.t + dt) },
                anchor = tr.anchor?.plus(dt), retain = tr.retain?.plus(dt)) },
        )
    }

    fun insertTime(local: Double, dt: Double): ClipStack {
        if (dt <= 1e-6) return this
        return copy(keyframes = keyframes.map { if (it.t > local + 1e-4) it.copy(t = it.t + dt) else it })
    }

    fun scaleTime(k: Double): ClipStack {
        if (abs(k - 1) <= 1e-9) return this
        return copy(
            keyframes = keyframes.map { it.copy(t = it.t * k) },
            stabilization = stabilization?.let { st -> st.copy(path = st.path.map { it.copy(t = it.t * k) }) },
            tracking = tracking?.let { tr -> tr.copy(samples = tr.samples.map { it.copy(t = it.t * k) },
                anchor = tr.anchor?.times(k), retain = tr.retain?.times(k)) },
        )
    }

    /** The Stack cut at Stack time `local` (its clips split there). */
    fun halves(local: Double, length: Double, firstIDs: List<UUID>, secondIDs: List<UUID>): Pair<ClipStack, ClipStack> {
        var a = copy(clipIDs = firstIDs)
        var b = copy(id = UUID.randomUUID(), clipIDs = secondIDs)
        if (keyframes.isNotEmpty()) {
            val here = look(local)
            a = a.copy(keyframes = keyframes.filter { it.t < local - 0.001 } + Keyframe(t = local, look = here))
            b = b.copy(keyframes = listOf(Keyframe(t = local, look = here)) + keyframes.filter { it.t > local + 0.001 })
        }
        val z = autoZoom
        if (z != null && length > 0.01) {
            val (za, zb) = z.halves((local / length).coerceIn(0.0, 1.0))
            a = a.copy(autoZoom = za); b = b.copy(autoZoom = zb)
        }
        a = a.copy(anim = a.anim.copy(outAnim = MotionAnim.none), fadeOut = 0.0)
        b = b.copy(anim = b.anim.copy(inAnim = MotionAnim.none), fadeIn = 0.0)
        return a to b.shiftTime(-local)
    }
}
