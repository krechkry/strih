// Text layers and captions over the picture (iOS: OverlayRenderer text + CaptionRenderer in FrameCompositor),
// as one Media3 BitmapOverlay the size of the canvas, used by the preview and the export alike. The frame is
// drawn again only when what shows changes (a new line, a layer coming in, a keyframe or an animation moving).
// Pictures are drawn too (fit, keyframes, animations); video layers play in the compositor. Not yet: blend modes, crop / mask / effects
// on pictures, pinned (tracked) layers, per-word caption animations.
@file:OptIn(androidx.media3.common.util.UnstableApi::class)
package cz.krechler.bombocut.engine

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PorterDuff
import androidx.media3.effect.BitmapOverlay
import androidx.media3.effect.OverlayEffect
import cz.krechler.bombocut.model.CaptionAnim
import cz.krechler.bombocut.model.CaptionStyle
import cz.krechler.bombocut.model.OverlayKind
import cz.krechler.bombocut.model.Project
import com.google.common.collect.ImmutableList
import kotlin.math.pow

/** The project the preview's text layer reads, so editing a text or a caption doesn't rebuild the composition. */
object LiveLayers { @Volatile var project: Project? = null }

class TextLayer(private val fixed: Project, private val w: Int, private val h: Int, private val live: Boolean) : BitmapOverlay() {
    private val project: Project get() = if (live) LiveLayers.project ?: fixed else fixed
    private val frame: Bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
    private var drawn: String? = null
    /** Text blocks by text + style (they don't change while the project is the same). */
    private val blocks = HashMap<Triple<String, CaptionStyle, String>, Bitmap?>()

    private data class Piece(val key: String, val text: String, val style: CaptionStyle, val wrap: Boolean,
                             val cx: Float, val cy: Float, val scale: Float, val rotation: Float, val alpha: Float,
                             /** A picture layer: its file and the share of the canvas it fits in at scale 1. */
                             val file: String? = null, val base: Pair<Double, Double>? = null,
                             /** Captions' per-word state: spoken word, words shown, letters typed (iOS CaptionRenderer). */
                             val active: Int? = null, val visibleWords: Int? = null, val typed: Double? = null)

    /** What shows at timeline time t, top layer last. */
    private fun pieces(t: Double): List<Piece> {
        val project = this.project
        val out = mutableListOf<Piece>()
        // captions under the text layers (iOS draws them first)
        project.captionTracks.forEachIndexed { k, caps ->
            val cue = caps.cue(t) ?: return@forEachIndexed
            val st = caps.style
            val local = t - cue.start
            val inT = minOf(1.0, local / 0.18); val outT = minOf(1.0, (cue.end - t) / 0.12)
            var alpha = 1.0; var scale = 1.0; var dy = 0.0
            when (st.anim) {
                CaptionAnim.fade, CaptionAnim.highlight, CaptionAnim.typewriter -> alpha = minOf(inT, outT)
                CaptionAnim.pop -> {
                    val p = minOf(1.0, local / 0.22)
                    scale = if (p < 0.6) 0.55 + (p / 0.6) * 0.6 else 1.15 - ((p - 0.6) / 0.4) * 0.15
                    alpha = minOf(1.0, local / 0.08)
                }
                CaptionAnim.slide -> {
                    val p = 1 - (1 - inT).pow(3)
                    dy = h * 0.035 * (1 - p)
                    alpha = minOf(p, outT)
                }
                CaptionAnim.words, CaptionAnim.none -> {}
            }
            if (alpha <= 0.004) return@forEachIndexed
            val spoken = cue.words.indexOfLast { it.start <= t }
            val dur = maxOf(cue.end - cue.start, 0.01)
            val typed = if (st.anim == CaptionAnim.typewriter)
                Math.round(minOf(1.0, local / maxOf(minOf(dur * 0.7, 1.6), 0.2)) * 40) / 40.0 else null
            out.add(Piece("c$k|${cue.id}", cue.text, st, false, (w / 2 + st.x * w).toFloat(), (h * st.y + dy).toFloat(),
                          scale.toFloat(), Math.toDegrees(st.rotation).toFloat(), alpha.toFloat(),
                          active = if (st.anim == CaptionAnim.highlight) maxOf(0, spoken) else null,
                          visibleWords = if (st.anim == CaptionAnim.words) maxOf(1, spoken + 1) else null,
                          typed = typed))
        }
        for (o in project.overlays) {
            val pic = o.kind as? OverlayKind.Image
            // video layers play as their own compositor inputs (CompositionBuilder.layerSequence)
            val text = (o.kind as? OverlayKind.Text)?.text
            if (text == null && pic == null) continue
            if (t < o.start - 1e-4 || t >= o.end) continue
            val (tr, opacity) = o.pose(t)
            val a = o.anim.pose(t - o.start, o.duration)
            val alpha = opacity * a.opacity
            if (alpha <= 0.004) continue
            out.add(Piece("o${o.id}", text ?: "", o.style, true, (w / 2 + (tr.x + a.dx) * w).toFloat(), (h / 2 + (tr.y + a.dy) * h).toFloat(),
                          (tr.scale * a.scale).toFloat(), Math.toDegrees(tr.rotation).toFloat(), alpha.toFloat(),
                          file = pic?.file,
                          base = if (pic != null) o.baseFraction(w.toDouble() / h) else null))
        }
        return out
    }

    private val pictures = HashMap<String, Bitmap?>()

    /** A picture layer's file, at most 2400 px on its long side (iOS keeps big photos manageable the same way). */
    private fun picture(file: String): Bitmap? = pictures.getOrPut(file) {
        runCatching {
            val f = cz.krechler.bombocut.model.Paths.mediaFile(file)
            val o = android.graphics.BitmapFactory.Options().apply { inJustDecodeBounds = true }
            android.graphics.BitmapFactory.decodeFile(f.path, o)
            var sample = 1
            while (maxOf(o.outWidth, o.outHeight) / sample > 2400) sample *= 2
            android.graphics.BitmapFactory.decodeFile(f.path, android.graphics.BitmapFactory.Options().apply { inSampleSize = sample })
        }.getOrNull()
    }

    private fun block(p: Piece): Bitmap? {
        p.file?.let { return picture(it) }
        // typing makes a new block per letter: keep the cache small
        if (blocks.size > 48) blocks.clear()
        return blocks.getOrPut(Triple(p.text, p.style, "${p.active}|${p.visibleWords}|${p.typed}")) {
            TextRenderer.render(p.text, p.style, w, h, p.wrap, p.active, p.visibleWords, p.typed)
        }
    }

    override fun getBitmap(presentationTimeUs: Long): Bitmap {
        val ps = pieces(presentationTimeUs / 1_000_000.0)
        // rounded, so a still layer doesn't redraw every frame
        val sig = ps.joinToString(";") { "${it.key}|${it.text.hashCode()}|${it.style.hashCode()}|${it.active}|${it.visibleWords}|${it.typed}|${(it.cx * 2).toInt()}|${(it.cy * 2).toInt()}|${(it.scale * 500).toInt()}|${(it.rotation * 10).toInt()}|${(it.alpha * 255).toInt()}" }
        if (sig == drawn) return frame
        drawn = sig
        val c = Canvas(frame)
        c.drawColor(Color.TRANSPARENT, PorterDuff.Mode.CLEAR)
        val paint = Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG)
        for (p in ps) {
            val b = block(p) ?: continue
            paint.alpha = (p.alpha * 255).toInt().coerceIn(0, 255)
            // a picture fits its share of the canvas (Overlay.baseFraction); text is drawn at the canvas' own size
            val fit = p.base?.let { (bw, bh) -> minOf(bw * w / b.width, bh * h / b.height).toFloat() } ?: 1f
            c.save()
            c.translate(p.cx, p.cy)
            c.rotate(p.rotation)
            c.scale(p.scale * fit, p.scale * fit)
            c.drawBitmap(b, -b.width / 2f, -b.height / 2f, paint)
            c.restore()
        }
        return frame
    }

    companion object {
        /** The layer as an effect, or null when the project has no text and no captions. */
        fun hasAny(project: Project): Boolean =
            project.captionTracks.any { it.cues.isNotEmpty() } || project.overlays.any { it.kind !is OverlayKind.Adjustment && it.kind !is OverlayKind.Video }

        /** `live`: the preview, reading LiveLayers; export takes the project as it is. */
        fun effect(project: Project, w: Int, h: Int, live: Boolean = false): OverlayEffect? {
            if (!hasAny(project)) return null
            return OverlayEffect(ImmutableList.of<androidx.media3.effect.TextureOverlay>(TextLayer(project, w, h, live)))
        }
    }
}
