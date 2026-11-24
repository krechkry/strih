// Ported from Bombocut/Engine/CaptionRenderer.swift (iOS ad3827a): the text block of a caption line or a text
// layer, drawn with Android's Canvas instead of Core Text. Same measures: size from the canvas' short side,
// 88 % of the width at most, padding, box per line, outline (outside only or centered) and a soft shadow.
// Not yet: the fonts that come with the app (FontCatalog, fontName), per-word colors (Highlight, Word by word).
package cz.krechler.bombocut.engine

import android.graphics.Bitmap
import android.graphics.BlurMaskFilter
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import cz.krechler.bombocut.model.CaptionFont
import cz.krechler.bombocut.model.CaptionStyle
import cz.krechler.bombocut.model.RGBA
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.sin

object TextRenderer {
    private fun argb(c: RGBA, alpha: Double = c.a): Int = Color.argb(
        (alpha.coerceIn(0.0, 1.0) * 255).toInt(), (c.r.coerceIn(0.0, 1.0) * 255).toInt(),
        (c.g.coerceIn(0.0, 1.0) * 255).toInt(), (c.b.coerceIn(0.0, 1.0) * 255).toInt())

    /** The nearest Android face to each iOS caption font. */
    fun typeface(f: CaptionFont): Typeface = when (f) {
        CaptionFont.heavy -> Typeface.create(Typeface.DEFAULT, 800, false)
        CaptionFont.rounded -> Typeface.create(Typeface.DEFAULT, 900, false)
        CaptionFont.condensed -> Typeface.create(Typeface.create("sans-serif-condensed", Typeface.BOLD), 900, false)
        CaptionFont.avenir -> Typeface.create(Typeface.DEFAULT, 800, false)
        CaptionFont.futura -> Typeface.create(Typeface.DEFAULT, 700, false)
        CaptionFont.serif -> Typeface.create(Typeface.SERIF, 700, false)
        CaptionFont.typewriter -> Typeface.create(Typeface.MONOSPACE, 700, false)
        CaptionFont.mono -> Typeface.create(Typeface.MONOSPACE, 700, false)
    }

    /** Words never break: a line longer than `maxWidth` goes on the next row at a space (Swift: wrapped). */
    fun wrapped(line: String, maxWidth: Float, width: (String) -> Float): List<String> {
        val words = line.split(" ").filter { it.isNotEmpty() }
        if (words.isEmpty()) return emptyList()
        val out = mutableListOf<String>()
        var current = ""
        for (w in words) {
            val next = if (current.isEmpty()) w else "$current $w"
            if (current.isEmpty() || width(next) <= maxWidth) current = next else { out.add(current); current = w }
        }
        out.add(current)
        return out
    }

    /**
     * The text block for a canvas of `cw` x `ch` pixels, or null for no text. `wrap`: text layers wrap at spaces
     * (only a word wider than the box shrinks the text); caption lines shrink to fit their widest line.
     */
    fun render(text: String, style: CaptionStyle, cw: Int, ch: Int, wrap: Boolean): Bitmap? {
        val short = minOf(cw, ch).toFloat()
        var fontSize = style.size.toFloat() * short
        val maxWidth = cw * 0.88f
        val raw = if (style.caps) text.uppercase() else text
        var lines = raw.split("\n").filter { it.isNotEmpty() }
        if (lines.isEmpty()) return null

        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            typeface = typeface(style.font)
            textSize = fontSize
            letterSpacing = style.tracking.toFloat()
        }
        fun width(s: String) = paint.measureText(s)
        if (wrap) {
            val widest = lines.flatMap { l -> l.split(" ").map { width(it) } }.maxOrNull() ?: 0f
            if (widest > maxWidth) { fontSize *= maxWidth / widest; paint.textSize = fontSize }
            lines = lines.flatMap { wrapped(it, maxWidth) { s -> width(s) } }
        } else {
            val widest = lines.maxOf { width(it) }
            if (widest > maxWidth) { fontSize *= maxWidth / widest; paint.textSize = fontSize }
        }
        if (lines.isEmpty()) return null

        val fm = paint.fontMetrics
        val lineHeight = fm.descent - fm.ascent
        val padX = if (style.box) fontSize * 0.35f else fontSize * 0.15f
        val padY = if (style.box) fontSize * 0.12f else fontSize * 0.05f
        val rowH = lineHeight + padY * 2
        val gap = if (style.box) fontSize * 0.08f else 0f
        val step = max(rowH + gap + (style.lineSpacing.toFloat() - 1) * lineHeight, 0f)
        val kern = style.tracking.toFloat() * fontSize
        val outline = style.strokeWidth.toFloat() * fontSize * 0.09f
        val outlineReach = if (style.strokeOutside) outline else outline / 2
        // trailing tracking after the last letter is not part of the text
        val widths = lines.map { width(it) - if (kern > 0) kern else 0f }

        val shadowOn = style.shadow && style.shadowOpacity > 0
        val angle = Math.toRadians(style.shadowAngle)
        val sdx = (cos(angle) * style.shadowDistance * fontSize).toFloat()
        val sdy = (sin(angle) * style.shadowDistance * fontSize).toFloat()
        val blur = style.shadowBlur.toFloat() * fontSize
        val shadowReach = if (shadowOn) max(abs(sdx), abs(sdy)) + blur * 1.5f else 0f
        val margin = fontSize * 0.1f + outlineReach + shadowReach

        val contentW = (widths.maxOrNull() ?: 0f) + padX * 2
        val contentH = rowH + (lines.size - 1) * step
        val bw = ceil(contentW + margin * 2).toInt().coerceAtLeast(1)
        val bh = ceil(contentH + margin * 2).toInt().coerceAtLeast(1)

        // the letters (box, outline, fill) first; the shadow is cast by all of it together, like iOS's layer
        val letters = Bitmap.createBitmap(bw, bh, Bitmap.Config.ARGB_8888)
        val c = Canvas(letters)
        val box = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = argb(style.boxColor, style.boxOpacity) }
        val stroke = Paint(paint).apply {
            this.style = Paint.Style.STROKE
            strokeJoin = Paint.Join.ROUND
            strokeCap = Paint.Cap.ROUND
            color = argb(style.stroke)
        }
        val fill = Paint(paint).apply { color = argb(style.text) }
        lines.forEachIndexed { i, line ->
            val w = widths[i]
            val y = margin + i * step
            val x = (bw - w) / 2
            if (style.box) c.drawRoundRect(RectF(x - padX, y, x + w + padX, y + rowH), fontSize * 0.22f, fontSize * 0.22f, box)
            val baseline = y + padY - fm.ascent
            if (outline > 0 && style.strokeOutside) { stroke.strokeWidth = outline * 2; c.drawText(line, x, baseline, stroke) }
            c.drawText(line, x, baseline, fill)
            if (outline > 0 && !style.strokeOutside) { stroke.strokeWidth = outline; c.drawText(line, x, baseline, stroke) }
        }
        if (!shadowOn) return letters

        val out = Bitmap.createBitmap(bw, bh, Bitmap.Config.ARGB_8888)
        val oc = Canvas(out)
        val alpha = letters.extractAlpha()
        val shadow = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.argb((style.shadowOpacity.coerceIn(0.0, 1.0) * 255).toInt(), 0, 0, 0)
            // Core Graphics' blur reads as about twice a Gaussian radius
            if (blur > 0.5f) maskFilter = BlurMaskFilter(blur * 0.5f, BlurMaskFilter.Blur.NORMAL)
        }
        oc.drawBitmap(alpha, sdx, sdy, shadow)
        oc.drawBitmap(letters, 0f, 0f, null)
        alpha.recycle()
        letters.recycle()
        return out
    }
}
