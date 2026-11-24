// Ported from Bombocut/App/BombocutApp.swift (iOS base ad3827a): Theme, Fmt, loc.
package cz.krechler.bombocut.app

import androidx.compose.ui.graphics.Color
import java.math.BigDecimal
import java.util.Locale
import kotlin.math.abs
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
        return fmt("%d:%04.1f", m, s)
    }

    /** 2x, 0.5x, 0.25x, 12x */
    fun speed(v: Double): String {
        if (v >= 10) return fmt("%.0fx", v)
        if (v >= 1) return g(Math.round(v * 10) / 10.0) + "x"
        return g(Math.round(v * 100) / 100.0) + "x"
    }

    /** +0.40s / −1.25s */
    fun delta(d: Double): String {
        val sign = if (d >= 0) "+" else "−"
        return sign + fmt("%.2fs", abs(d))
    }

    fun duration(t: Double): String {
        val t0 = maxOf(0.0, t)
        if (t0 < 60) return fmt("%.1fs", t0)
        return fmt("%d:%02d", t0.toInt() / 60, t0.toInt() % 60)
    }

    /** C's %g for the short numbers above: no trailing zeros (Java's %g keeps them). */
    fun g(v: Double): String {
        if (v == v.roundToLong().toDouble() && abs(v) < 1e15) return v.roundToLong().toString()
        return BigDecimal(v.toString()).stripTrailingZeros().toPlainString()
    }
}
