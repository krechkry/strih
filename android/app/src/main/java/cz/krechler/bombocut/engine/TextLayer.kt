// Text layers and captions over the picture (iOS: OverlayRenderer text + CaptionRenderer in FrameCompositor),
// as one Media3 BitmapOverlay the size of the canvas, used by the preview and the export alike. The frame is
// drawn again only when what shows changes (a new line, a layer coming in, a keyframe or an animation moving).
// Not yet: pictures and video layers, blend modes, pinned (tracked) texts, per-word caption animations.
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
    private val blocks = HashMap<Pair<String, CaptionStyle>, Bitmap?>()

    private data class Piece(val key: String, val text: String, val style: CaptionStyle, val wrap: Boolean,
                             val cx: Float, val cy: Float, val scale: Float, val rotation: Float, val alpha: Float)

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
            out.add(Piece("c$k|${cue.id}", cue.text, st, false, (w / 2 + st.x * w).toFloat(), (h * st.y + dy).toFloat(),
                          scale.toFloat(), Math.toDegrees(st.rotation).toFloat(), alpha.toFloat()))
        }
        for (o in project.overlays) {
            val text = (o.kind as? OverlayKind.Text)?.text ?: continue
            if (t < o.start - 1e-4 || t >= o.end) continue
            val (tr, opacity) = o.pose(t)
            val a = o.anim.pose(t - o.start, o.duration)
            val alpha = opacity * a.opacity
            if (alpha <= 0.004) continue
            out.add(Piece("o${o.id}", text, o.style, true, (w / 2 + (tr.x + a.dx) * w).toFloat(), (h / 2 + (tr.y + a.dy) * h).toFloat(),
                          (tr.scale * a.scale).toFloat(), Math.toDegrees(tr.rotation).toFloat(), alpha.toFloat()))
        }
        return out
    }

    private fun block(p: Piece): Bitmap? {
        // typing makes a new block per letter: keep the cache small
        if (blocks.size > 48) blocks.clear()
        return blocks.getOrPut(p.text to p.style) { TextRenderer.render(p.text, p.style, w, h, p.wrap) }
    }

    override fun getBitmap(presentationTimeUs: Long): Bitmap {
        val ps = pieces(presentationTimeUs / 1_000_000.0)
        // rounded, so a still layer doesn't redraw every frame
        val sig = ps.joinToString(";") { "${it.key}|${it.text.hashCode()}|${it.style.hashCode()}|${(it.cx * 2).toInt()}|${(it.cy * 2).toInt()}|${(it.scale * 500).toInt()}|${(it.rotation * 10).toInt()}|${(it.alpha * 255).toInt()}" }
        if (sig == drawn) return frame
        drawn = sig
        val c = Canvas(frame)
        c.drawColor(Color.TRANSPARENT, PorterDuff.Mode.CLEAR)
        val paint = Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG)
        for (p in ps) {
            val b = block(p) ?: continue
            paint.alpha = (p.alpha * 255).toInt().coerceIn(0, 255)
            c.save()
            c.translate(p.cx, p.cy)
            c.rotate(p.rotation)
            c.scale(p.scale, p.scale)
            c.drawBitmap(b, -b.width / 2f, -b.height / 2f, paint)
            c.restore()
        }
        return frame
    }

    companion object {
        /** The layer as an effect, or null when the project has no text and no captions. */
        fun hasAny(project: Project): Boolean =
            project.captionTracks.any { it.cues.isNotEmpty() } || project.overlays.any { it.kind is OverlayKind.Text }

        /** `live`: the preview, reading LiveLayers; export takes the project as it is. */
        fun effect(project: Project, w: Int, h: Int, live: Boolean = false): OverlayEffect? {
            if (!hasAny(project)) return null
            return OverlayEffect(ImmutableList.of<androidx.media3.effect.TextureOverlay>(TextLayer(project, w, h, live)))
        }
    }
}
