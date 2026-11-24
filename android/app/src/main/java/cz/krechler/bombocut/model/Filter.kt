// Ported from Bombocut/Model/Filter.swift (iOS ad3827a). Part 1: what a clip stores (LookFilter, MyFilter,
// FilterFX). The filter library (FilterDef, FilterLibrary, the LUT formulas) comes with the look engine.
package cz.krechler.bombocut.model

import kotlinx.serialization.Serializable

/** A filter on a clip, a Stack or a layer: one look from the library and how strong it is. */
@Serializable
data class LookFilter(
    /** A built-in id ("bw", "orangeTeal"...), "lut:<file>" for an imported LUT, "my:<uuid>" for your own. */
    val id: String,
    val strength: Double = 1.0,
    /** The film effects changed in the filter's Adjust menu (nil = the filter's own). */
    val fx: FilterFX? = null,
    /** A filter you saved from Adjust: a copy of its look travels with every clip that uses it. */
    val own: MyFilter? = null,
    /** Its sliders moved here (LookParam name → value), on top of the saved look. */
    val tweaks: Map<String, Double>? = null,
) {
    /** A saved filter's look at full strength, with the sliders moved here (nil for library filters). */
    val ownEffects: Effects?
        get() {
            val o = own ?: return null
            if (tweaks.isNullOrEmpty()) return o.effects
            var l = Look(effects = o.effects)
            for ((k, v) in tweaks) LookParam.entries.firstOrNull { it.name == k }?.let { l = it.set(l, v) }
            return l.effects
        }

    fun ownValue(p: LookParam): Double? {
        val o = own ?: return null
        tweaks?.get(p.name)?.let { return it }
        return p.get(Look(effects = o.effects))
    }
}

/** A look you saved from Adjust as a filter, and which of its sliders stay movable. */
@Serializable
data class MyFilter(val id: String, val name: String, val effects: Effects, val sliders: List<String>) {
    val params: List<LookParam> get() = sliders.mapNotNull { s -> LookParam.entries.firstOrNull { it.name == s } }

    companion object {
        val savable: List<LookParam> = LookParam.basic.filter { it != LookParam.opacity } + LookParam.effects
        fun changed(e: Effects): List<LookParam> { val l = Look(effects = e); return savable.filter { kotlin.math.abs(it.get(l) - it.neutral) > 0.005 } }
        fun look(e: Effects): Effects = e.copy(motionBlur = 0.0)
    }
}

/** The film effects a filter adds on top of its colors (at full strength). */
@Serializable
data class FilterFX(val grain: Double = 0.0, val grainSize: Double = 0.4, val vignette: Double = 0.0, val halation: Double = 0.0) {
    val isEmpty: Boolean get() = grain < 0.001 && vignette < 0.001 && halation < 0.001
}
