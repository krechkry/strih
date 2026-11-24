// Ported from Bombocut/App/BombocutApp.swift (iOS base ad3827a): Theme, Fmt, loc.
package cz.krechler.bombocut.app

import androidx.compose.ui.graphics.Color
import java.math.BigDecimal
import java.math.RoundingMode
import java.util.Locale
import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.roundToLong

/** Looks up the translation of a UI string in the app language (same English keys as iOS). */
fun loc(s: String): String = AppLanguage.strings.translate(s)

/** String(format:) the way Swift does it: always a dot for decimals, whatever the phone's language. */
fun fmt(format: String, vararg args: Any?): String = String.format(Locale.ROOT, format, *args)

object Theme {
    val accent = Color(0.894f, 1.0f, 0.353f)    // #E4FF5A
    val bg = Color(0.05f, 0.055f, 0.063f)
    val panel = Color(0.085f, 0.09f, 0.10f)
    val panel2 = Color(0.12f, 0.125f, 0.14f)
    val line = Color.White.copy(alpha = 0.09f)
    val muted = Color.White.copy(alpha = 0.5f)
}

object Fmt {
    /** 0:03.2 style for the transport bar */
    fun time(t: Double): String {
        val t0 = maxOf(0.0, t)
        val m = t0.toInt() / 60
        val s = t0 - m * 60
        return "$m:" + cFixed(s, 1).padStart(4, '0')
    }

    /** 2x, 0.5x, 0.25x, 12x */
    fun speed(v: Double): String {
        if (v >= 10) return cFixed(v, 0) + "x"
        if (v >= 1) return g(swiftRounded(v * 10) / 10) + "x"
        return g(swiftRounded(v * 100) / 100) + "x"
    }

    /** +0.40s / −1.25s */
    fun delta(d: Double): String {
        val sign = if (d >= 0) "+" else "−"
        return sign + cFixed(abs(d), 2) + "s"
    }

    fun duration(t: Double): String {
        val t0 = maxOf(0.0, t)
        if (t0 < 60) return cFixed(t0, 1) + "s"
        return fmt("%d:%02d", t0.toInt() / 60, t0.toInt() % 60)
    }

    /** Swift `Double.rounded()`: halves away from zero (Kotlin's Math.round goes toward +infinity). */
    fun swiftRounded(v: Double): Double = if (v >= 0) floor(v + 0.5) else -floor(-v + 0.5)

    /**
     * C's "%.nf" (what Swift's String(format:) uses): the exact binary value rounded half to even, so 0.25
     * gives "0.2" like on iOS (Java's %.1f gives "0.3").
     */
    fun cFixed(v: Double, decimals: Int): String =
        BigDecimal(v).setScale(decimals, RoundingMode.HALF_EVEN).toPlainString().let { if (it.startsWith("-") && it.trim('-', '0', '.').isEmpty()) it.drop(1) else it }

    /** C's %g for the short numbers above: no trailing zeros (Java's %g keeps them). */
    fun g(v: Double): String {
        if (v == v.roundToLong().toDouble() && abs(v) < 1e15) return v.roundToLong().toString()
        return BigDecimal(v.toString()).stripTrailingZeros().toPlainString()
    }
}

/** A translated string with iOS format specifiers (%lld, %@) filled in like Swift's String(format:). */
fun locf(key: String, vararg args: Any?): String =
    fmt(loc(key).replace("%lld", "%d").replace("%ld", "%d").replace("%@", "%s"), *args)
