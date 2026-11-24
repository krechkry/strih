// A clip's Adjust light / color as a 3D LUT built from LookMath (the iPhone's EffectsRenderer.color math), applied
// by Media3 on the GPU. Same numbers as the reference, no second shader to keep in step. Keyframed looks (a LUT per
// moment) come with the look engine.
@file:OptIn(androidx.media3.common.util.UnstableApi::class)
package cz.krechler.bombocut.engine

import android.util.LruCache
import androidx.media3.effect.SingleColorLut
import cz.krechler.bombocut.model.Effects
import kotlin.math.roundToInt

object LookLut {
    const val SIZE = 33
    private val cache = LruCache<Effects, SingleColorLut>(24)

    /** The cube for these effects: cube[r][g][b] = ARGB of what that color becomes. */
    fun cube(e: Effects, n: Int = SIZE): Array<Array<IntArray>> = Array(n) { r ->
        Array(n) { g ->
            IntArray(n) { b ->
                val out = LookMath.color(doubleArrayOf(r / (n - 1.0), g / (n - 1.0), b / (n - 1.0)), e)
                val R = (out[0] * 255).roundToInt(); val G = (out[1] * 255).roundToInt(); val B = (out[2] * 255).roundToInt()
                (0xFF shl 24) or (R shl 16) or (G shl 8) or B
            }
        }
    }

    /** Media3's LUT effect for a clip's look, nil when it changes nothing. */
    fun effect(e: Effects): SingleColorLut? {
        if (!e.hasColor) return null
        cache.get(e)?.let { return it }
        return SingleColorLut.createFromCube(cube(e)).also { cache.put(e, it) }
    }
}
