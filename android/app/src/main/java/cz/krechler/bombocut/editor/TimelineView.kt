// Ported in part from Bombocut/Editor/TimelineView.swift (iOS ad3827a): ruler, clip strip with a filmstrip,
// fixed center playhead, pinch zoom, drag to scrub, tap to select, ripple trim handles, and the lanes in desktop
// order (captions, layers, clips, sound) showing what is where.
// Not yet: editing in the lanes (select, move, trim), hold-to-reorder, transitions, stacks, snapping lines, slip.
package cz.krechler.bombocut.editor

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import cz.krechler.bombocut.app.Theme
import cz.krechler.bombocut.engine.ThumbnailCache
import cz.krechler.bombocut.app.loc
import cz.krechler.bombocut.model.AudioItem
import cz.krechler.bombocut.model.Clip
import kotlin.math.roundToInt

object LaneLayout {
    val top = 26.dp      // ruler
    val strip = 60.dp    // clips
    val gap = 4.dp
    val caption = 18.dp  // one caption track
    val layer = 26.dp    // one row of layers
    val sound = 28.dp    // one row of sounds
    const val rowGap = 3f

    /** Sounds in rows: one that overlaps the row's last goes on the next row. */
    fun soundRows(list: List<AudioItem>): List<List<AudioItem>> {
        val rows = mutableListOf<MutableList<AudioItem>>()
        for (a in list.sortedBy { it.start }) {
            val r = rows.firstOrNull { it.last().end <= a.start + 1e-6 }
            if (r != null) r.add(a) else rows.add(mutableListOf(a))
        }
        return rows
    }

    fun stack(n: Int, row: Dp): Dp = if (n == 0) 0.dp else row * n + (rowGap * (n - 1)).dp
}

/** Timeline state that only the strip needs: zoom (points per second of timeline). */
class TimelineState { var pxPerSec by mutableStateOf(60f) }

@Composable
fun TimelineView(model: EditorModel, tl: TimelineState, scrub: (Double) -> Unit, modifier: Modifier = Modifier,
                 pick: (String) -> Unit = {}) {
    val density = LocalDensity.current
    val p = model.project
    val layerRows = p.overlayRows()
    val soundRows = LaneLayout.soundRows(p.audio)
    val capH = LaneLayout.stack(p.captionTracks.size, LaneLayout.caption)
    val layH = LaneLayout.stack(layerRows.size, LaneLayout.layer)
    val sndH = LaneLayout.stack(soundRows.size, LaneLayout.sound)
    fun withGap(h: Dp) = if (h > 0.dp) h + LaneLayout.gap else 0.dp
    val stripY = LaneLayout.top + withGap(capH) + withGap(layH)
    BoxWithConstraints(
        modifier
            .fillMaxWidth()
            .height(stripY + LaneLayout.strip + withGap(sndH) + 16.dp)
            .background(Theme.bg)
            // two fingers: zoom; one finger sideways: scrub (the strip moves under the fixed playhead)
            .pointerInput(Unit) {
                detectTransformGestures { _, pan, zoom, _ ->
                    if (zoom != 1f) tl.pxPerSec = (tl.pxPerSec * zoom).coerceIn(8f, 600f)
                    if (pan.x != 0f) {
                        val dpPerSec = tl.pxPerSec * density.density
                        scrub((model.currentTime - pan.x / dpPerSec).coerceIn(0.0, model.duration))
                    }
                }
            }
            .pointerInput(Unit) { detectTapGestures { model.selectedClipID = null; model.selectedOverlayID = null; model.selectedAudioID = null } },
    ) {
        val center = maxWidth / 2
        val px = tl.pxPerSec
        val x0 = center - (model.currentTime * px).dp   // where timeline 0 sits
        Ruler(x0, px, model.duration)
        val starts = model.project.clipStarts
        model.project.clips.forEachIndexed { i, c ->
            ClipBlock(model, c, x0 + (starts[i] * px).dp, (c.duration * px).toFloat(), px, stripY)
        }
        // captions on top, one lane per track
        p.captionTracks.forEachIndexed { k, caps ->
            val y = LaneLayout.top + (LaneLayout.caption + LaneLayout.rowGap.dp) * k
            caps.cues.forEach { cue ->
                LaneBlock(x0 + (cue.start * px).dp, ((cue.end - cue.start) * px).toFloat(), y, LaneLayout.caption,
                          Theme.accent.copy(alpha = if (p.activeCaption == k) 0.4f else 0.22f), cue.text, Color.White)
            }
        }
        // layers: the higher row is drawn on top, the lowest sits right above the clips
        layerRows.forEachIndexed { r, row ->
            val y = LaneLayout.top + withGap(capH) + (LaneLayout.layer + LaneLayout.rowGap.dp) * r
            row.forEach { o ->
                LaneBlock(x0 + (o.start * px).dp, (o.duration * px).toFloat(), y, LaneLayout.layer,
                          Theme.panel2, if (o.isText) o.title else loc(o.title), Color.White,
                          selected = model.selectedOverlayID == o.id) {
                    if (model.selectedOverlayID == o.id) model.selectOverlay(null)
                    else { model.selectOverlay(o.id); pick(if (o.isText) "text" else "picture") }
                }
            }
        }
        // sound below the clips
        soundRows.forEachIndexed { r, row ->
            val y = stripY + LaneLayout.strip + LaneLayout.gap + (LaneLayout.sound + LaneLayout.rowGap.dp) * r
            row.forEach { a ->
                LaneBlock(x0 + (a.start * px).dp, (a.duration * px).toFloat(), y, LaneLayout.sound,
                          Color(0xFF1F6F4A), a.name, Color.White, selected = model.selectedAudioID == a.id) {
                    if (model.selectedAudioID == a.id) model.selectAudio(null) else { model.selectAudio(a.id); pick("sound") }
                }
            }
        }
        // the fixed playhead
        Box(Modifier.offset(x = center - 1.dp).width(2.dp).fillMaxHeight().background(Color.White))
    }
}

@Composable
private fun Ruler(x0: Dp, px: Float, duration: Double) {
    val step = when { px >= 120 -> 0.5; px >= 40 -> 1.0; px >= 15 -> 5.0; else -> 10.0 }
    Canvas(Modifier.fillMaxWidth().height(LaneLayout.top)) {
        val start = x0.toPx()
        var t = 0.0
        while (t <= duration + 0.001) {
            val x = start + (t * px).toFloat() * density
            if (x > -10 && x < size.width + 10) {
                val major = (t % (step * 2)) < 1e-6
                drawLine(Theme.muted, Offset(x, size.height - (if (major) 10f else 5f) * density), Offset(x, size.height), strokeWidth = density)
            }
            t += step
        }
    }
}

@Composable
private fun LaneBlock(x: Dp, widthDp: Float, y: Dp, height: Dp, fill: Color, label: String, ink: Color,
                      selected: Boolean = false, tap: (() -> Unit)? = null) {
    Box(
        Modifier
            .offset(x = x, y = y)
            .size(maxOf(4f, widthDp - 1).dp, height)
            .clip(RoundedCornerShape(4.dp))
            .background(fill)
            .border(if (selected) 2.dp else 0.dp, if (selected) Theme.accent else Color.Transparent, RoundedCornerShape(4.dp))
            .then(if (tap != null) Modifier.pointerInput(tap) { detectTapGestures { tap() } } else Modifier),
        contentAlignment = Alignment.CenterStart,
    ) {
        androidx.compose.material3.Text(label, color = ink, maxLines = 1,
            fontSize = androidx.compose.ui.unit.TextUnit(10f, androidx.compose.ui.unit.TextUnitType.Sp),
            fontWeight = androidx.compose.ui.text.font.FontWeight.Bold,
            modifier = Modifier.offset(x = 5.dp))
    }
}

@Composable
private fun ClipBlock(model: EditorModel, c: Clip, x: Dp, widthDp: Float, px: Float, stripY: Dp) {
    val selected = model.selectedClipID == c.id
    val shape = RoundedCornerShape(6.dp)
    val tileW = (LaneLayout.strip.value * (c.aspect ?: (9.0 / 16)).toFloat()).coerceIn(24f, 110f)
    val tiles = maxOf(1, kotlin.math.ceil(widthDp / tileW).toInt())
    Box(
        Modifier
            .offset(x = x, y = stripY)
            .size(widthDp.dp, LaneLayout.strip)
            .clip(shape)
            .background(Theme.panel2)
            .border(if (selected) 2.5.dp else 0.dp, if (selected) Theme.accent else Color.Transparent, shape)
            .pointerInput(c.id) { detectTapGestures { model.selectedClipID = if (selected) null else c.id } },
    ) {
        Row {
            val rt = c.retime
            for (k in 0 until tiles) {
                // the frame shown at the middle of the tile (follows speed curves)
                val local = ((k + 0.5) * tileW / px).coerceAtMost(rt.outDuration)
                val src = rt.source(local)
                val img by produceState<ImageBitmap?>(null, c.mediaFile, (src * 4).roundToInt()) {
                    value = ThumbnailCache.image(c.mediaFile, src, 160)?.asImageBitmap()
                }
                Box(Modifier.size(tileW.dp, LaneLayout.strip)) {
                    img?.let { Image(it, null, Modifier.size(tileW.dp, LaneLayout.strip), contentScale = ContentScale.Crop) }
                }
            }
        }
        c.speedLabel?.let {
            androidx.compose.material3.Text(it, color = Color.Black, fontSize = androidx.compose.ui.unit.TextUnit(10f, androidx.compose.ui.unit.TextUnitType.Sp),
                modifier = Modifier.align(Alignment.TopStart).background(Theme.accent, RoundedCornerShape(bottomEnd = 4.dp)).offsetPad())
        }
    }
    if (selected) {
        TrimHandle(model, c, x, leading = true, px, stripY)
        TrimHandle(model, c, x + widthDp.dp, leading = false, px, stripY)
    }
}

private fun Modifier.offsetPad() = this.then(Modifier.offset { IntOffset(0, 0) })

@Composable
private fun TrimHandle(model: EditorModel, c: Clip, edgeX: Dp, leading: Boolean, px: Float, stripY: Dp) {
    var dx by remember { mutableStateOf(0f) }
    val w = 16.dp
    Box(
        Modifier
            .offset(x = if (leading) edgeX - w else edgeX, y = stripY)
            .size(w, LaneLayout.strip)
            .background(Theme.accent, RoundedCornerShape(if (leading) 6.dp else 0.dp, if (leading) 0.dp else 6.dp, if (leading) 0.dp else 6.dp, if (leading) 6.dp else 0.dp))
            .pointerInput(c.id, leading) {
                detectHorizontalDragGestures(
                    onDragStart = { dx = 0f; model.trimBegan(c.id) },
                    onDragEnd = { model.trimEnded() },
                    onDragCancel = { model.trimEnded() },
                ) { _, amount ->
                    dx += amount / density
                    model.trimChanged(c.id, leading, (dx / px).toDouble())
                }
            },
        contentAlignment = Alignment.Center,
    ) { Box(Modifier.size(3.dp, 22.dp).background(Color.Black, RoundedCornerShape(2.dp))) }
}
