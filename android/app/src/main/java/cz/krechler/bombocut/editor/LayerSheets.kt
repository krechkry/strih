// Part port of Bombocut/Editor/EditorModel.swift (addText, sounds) and the text / sound panels (iOS ad3827a):
// add a text or a sound at the playhead, pick them in their lanes, change the words, size, volume, fades, delete.
// Not yet: fonts, colors, outline / shadow / box tabs, presets, keyframes, moving and trimming in the lanes.
package cz.krechler.bombocut.editor

import android.content.Context
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.provider.OpenableColumns
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.horizontalScroll
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import cz.krechler.bombocut.app.Fmt
import cz.krechler.bombocut.app.Theme
import cz.krechler.bombocut.app.loc
import cz.krechler.bombocut.model.AudioItem
import cz.krechler.bombocut.model.Defaults
import cz.krechler.bombocut.model.Media
import cz.krechler.bombocut.model.Overlay
import cz.krechler.bombocut.model.OverlayKind
import cz.krechler.bombocut.model.Paths
import cz.krechler.bombocut.model.restyled
import java.io.File
import java.util.UUID

fun EditorModel.selectOverlay(id: UUID?) { selectedOverlayID = id; if (id != null) { selectedClipID = null; selectedAudioID = null; selectedCue = null } }
fun EditorModel.selectAudio(id: UUID?) { selectedAudioID = id; if (id != null) { selectedClipID = null; selectedOverlayID = null; selectedCue = null } }
fun EditorModel.selectCue(track: Int, id: UUID?) {
    selectedCue = id?.let { track to it }
    if (id != null) { selectedClipID = null; selectedOverlayID = null; selectedAudioID = null }
}

val EditorModel.selectedCueLine: cz.krechler.bombocut.model.CaptionCue? get() {
    val (k, id) = selectedCue ?: return null
    return project.captionTracks.getOrNull(k)?.cues?.firstOrNull { it.id == id }
}

/** A caption line's words typed again (iOS: CaptionCue.setText), or the line gone. */
fun EditorModel.setCueText(track: Int, id: UUID, text: String) = mutate { p ->
    val tracks = p.captionTracks.toMutableList()
    val caps = tracks.getOrNull(track) ?: return@mutate p
    tracks[track] = caps.copy(cues = caps.cues.map { if (it.id == id) it.withText(text) else it })
    p.copy(captionTracks = tracks)
}

fun EditorModel.deleteCue(track: Int, id: UUID) {
    mutate { p ->
        val tracks = p.captionTracks.toMutableList()
        val caps = tracks.getOrNull(track) ?: return@mutate p
        tracks[track] = caps.copy(cues = caps.cues.filter { it.id != id })
        p.copy(captionTracks = tracks)
    }
    selectedCue = null
}

val EditorModel.selectedOverlay: Overlay? get() = selectedOverlayID?.let { id -> project.overlays.firstOrNull { it.id == id } }
val EditorModel.selectedAudio: AudioItem? get() = selectedAudioID?.let { id -> project.audio.firstOrNull { it.id == id } }

/** A text at the playhead (Defaults.layerLength long, a bit above the middle), picked and ready to type. */
fun EditorModel.addText(text: String = loc("Text")) {
    val start = minOf(currentTime, maxOf(0.0, duration - 0.5))
    val o = Overlay(kind = OverlayKind.Text(text), start = start, duration = minOf(Defaults.layerLength, maxOf(0.5, duration - start)),
                    transform = cz.krechler.bombocut.model.ClipTransform(y = -0.15))
    mutate { p -> p.copy(overlays = p.overlays + o) }
    selectOverlay(o.id)
}

fun EditorModel.changeOverlay(id: UUID, change: (Overlay) -> Overlay) {
    val i = project.overlays.indexOfFirst { it.id == id }.takeIf { it >= 0 } ?: return
    val n = change(project.overlays[i])
    if (n == project.overlays[i]) return
    mutate { p -> p.copy(overlays = p.overlays.toMutableList().also { it[i] = n }) }
}

fun EditorModel.deleteOverlay(id: UUID) {
    mutate { p -> p.copy(overlays = p.overlays.filter { it.id != id }) }
    selectedOverlayID = null
}

/** A sound file at the playhead, as long as it is (or up to the end of the video). */
fun EditorModel.addSound(file: String, name: String, length: Double) {
    val start = minOf(currentTime, maxOf(0.0, duration - 0.5))
    val a = AudioItem(file = file, name = name, sourceDuration = length, start = start,
                      duration = minOf(length, maxOf(0.5, duration - start)))
    mutate { p -> p.copy(audio = p.audio + a) }
    selectAudio(a.id)
}

fun EditorModel.changeAudio(id: UUID, change: (AudioItem) -> AudioItem) {
    val i = project.audio.indexOfFirst { it.id == id }.takeIf { it >= 0 } ?: return
    val n = change(project.audio[i])
    if (n == project.audio[i]) return
    mutate { p -> p.copy(audio = p.audio.toMutableList().also { it[i] = n }) }
}

fun EditorModel.deleteAudio(id: UUID) {
    mutate { p -> p.copy(audio = p.audio.filter { it.id != id }) }
    selectedAudioID = null
}

/** A picture at the playhead, fitted inside 70 % of the canvas (Overlay.baseFraction), picked. */
fun EditorModel.addPicture(file: String, aspect: Double) {
    val start = minOf(currentTime, maxOf(0.0, duration - 0.5))
    val o = Overlay(kind = OverlayKind.Image(file), start = start, duration = minOf(Defaults.layerLength, maxOf(0.5, duration - start)),
                    aspect = aspect)
    mutate { p -> p.copy(overlays = p.overlays + o) }
    selectOverlay(o.id)
}

object PictureImport {
    /** Copies the picked picture in and adds it at the playhead; false when it can't be read. */
    suspend fun add(context: Context, uri: Uri, model: EditorModel): Boolean {
        val f = Media.copyIn(context, uri) ?: return false
        val o = android.graphics.BitmapFactory.Options().apply { inJustDecodeBounds = true }
        android.graphics.BitmapFactory.decodeFile(f.path, o)
        if (o.outWidth <= 0 || o.outHeight <= 0) { f.delete(); return false }
        model.addPicture(f.name, o.outWidth.toDouble() / o.outHeight)
        return true
    }
}

@Composable
fun PictureSheet(model: EditorModel) {
    val o = model.selectedOverlay ?: return
    var op by remember(o.id, o.opacity) { mutableStateOf(o.opacity) }
    Row {
        Text(loc("Opacity"), color = Theme.muted, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
        Text("${(op * 100).toInt()} %", color = Color.White, fontWeight = FontWeight.Bold)
    }
    BSlider(op, 0.0..1.0, { op = it }, { model.changeOverlay(o.id) { it.copy(opacity = op) } })
    var sc by remember(o.id, o.transform.scale) { mutableStateOf(o.transform.scale) }
    Row {
        Text(loc("Scale"), color = Theme.muted, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
        Text("${(sc * 100).toInt()} %", color = Color.White, fontWeight = FontWeight.Bold)
    }
    BSlider(sc, 0.1..3.0, { sc = it }, { model.changeOverlay(o.id) { it.copy(transform = it.transform.copy(scale = sc)) } })
    TextButton({ model.deleteOverlay(o.id) }) { Text(loc("Delete"), color = Color(0xFFFF453A), fontWeight = FontWeight.Bold) }
}

object SoundImport {
    /** The picked file's name without its extension (what the sound lane shows). */
    fun name(context: Context, uri: Uri): String = runCatching {
        context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst()) c.getString(0) else null
        }
    }.getOrNull()?.substringBeforeLast('.') ?: loc("Sound")

    /** Length of the file's sound in seconds, null when it has none. */
    fun length(file: File): Double? = runCatching {
        val r = MediaMetadataRetriever()
        try {
            r.setDataSource(file.path)
            if (r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_AUDIO) != "yes") return null
            r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toDoubleOrNull()?.div(1000.0)
        } finally { r.release() }
    }.getOrNull()

    /** Copies the file in and adds it at the playhead; false when it has no sound. */
    suspend fun add(context: Context, uri: Uri, model: EditorModel): Boolean {
        val f = Media.copyIn(context, uri) ?: return false
        val len = length(f) ?: run { f.delete(); return false }
        model.addSound(f.name, name(context, uri), len)
        return true
    }
}

@Composable
fun TextSheet(model: EditorModel) {
    val o = model.selectedOverlay ?: return
    val k = o.kind as? OverlayKind.Text ?: return
    var text by remember(o.id) { mutableStateOf(k.text) }
    OutlinedTextField(
        text, { text = it; model.changeOverlay(o.id) { ov -> ov.copy(kind = OverlayKind.Text(it)) } },
        Modifier.fillMaxWidth(),
        colors = OutlinedTextFieldDefaults.colors(focusedTextColor = Color.White, unfocusedTextColor = Color.White,
                                                  focusedBorderColor = Theme.accent, cursorColor = Theme.accent),
    )
    var size by remember(o.id, o.style.size) { mutableStateOf(o.style.size) }
    Row {
        Text(loc("Size"), color = Theme.muted, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
        Text("${(size * 1000).toInt()}", color = Color.White, fontWeight = FontWeight.Bold)
    }
    BSlider(size, 0.03..0.28, { size = it }, { model.changeOverlay(o.id) { ov -> ov.copy(style = ov.style.copy(size = size)) } })
    FontPills(o.style.font) { f -> model.changeOverlay(o.id) { ov -> ov.copy(style = ov.style.copy(font = f, fontName = null)) } }
    Text(loc("Color"), color = Theme.muted, fontWeight = FontWeight.Bold)
    Swatches(o.style.text) { c -> model.changeOverlay(o.id) { ov -> ov.copy(style = ov.style.copy(text = c)) } }
    var outline by remember(o.id, o.style.strokeWidth) { mutableStateOf(o.style.strokeWidth) }
    Row {
        Text(loc("Outline"), color = Theme.muted, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
        Text("${(outline * 100).toInt()}", color = Color.White, fontWeight = FontWeight.Bold)
    }
    BSlider(outline, 0.0..1.0, { outline = it }, { model.changeOverlay(o.id) { ov -> ov.copy(style = ov.style.copy(strokeWidth = outline)) } })
    OnOffRow("Shadow", isOn = o.style.shadow) { on -> model.changeOverlay(o.id) { ov -> ov.copy(style = ov.style.copy(shadow = on)) } }
    OnOffRow("Box", isOn = o.style.box) { on -> model.changeOverlay(o.id) { ov -> ov.copy(style = ov.style.copy(box = on)) } }
    TextButton({ model.deleteOverlay(o.id) }) { Text(loc("Delete"), color = Color(0xFFFF453A), fontWeight = FontWeight.Bold) }
}

@Composable
fun SoundSheet(model: EditorModel) {
    val a = model.selectedAudio ?: return
    Text(a.name, color = Color.White, fontWeight = FontWeight.Bold)
    var vol by remember(a.id, a.volume) { mutableStateOf(a.volume) }
    Row {
        Text(loc("Volume"), color = Theme.muted, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
        Text("${(vol * 100).toInt()} %", color = Color.White, fontWeight = FontWeight.Bold)
    }
    BSlider(vol, 0.0..2.0, { vol = it }, { model.changeAudio(a.id) { it.copy(volume = vol) } })
    var fin by remember(a.id, a.fadeIn) { mutableStateOf(a.fadeIn ?: 0.0) }
    Row {
        Text(loc("Fade in"), color = Theme.muted, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
        Text(Fmt.cFixed(fin, 1) + " s", color = Color.White, fontWeight = FontWeight.Bold)
    }
    BSlider(fin, 0.0..3.0, { fin = it }, { model.changeAudio(a.id) { it.copy(fadeIn = fin.takeIf { v -> v > 0.01 }) } })
    var fout by remember(a.id, a.fadeOut) { mutableStateOf(a.fadeOut ?: 0.0) }
    Row {
        Text(loc("Fade out"), color = Theme.muted, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
        Text(Fmt.cFixed(fout, 1) + " s", color = Color.White, fontWeight = FontWeight.Bold)
    }
    BSlider(fout, 0.0..3.0, { fout = it }, { model.changeAudio(a.id) { it.copy(fadeOut = fout.takeIf { v -> v > 0.01 }) } })
    TextButton({ model.deleteAudio(a.id) }) { Text(loc("Delete"), color = Color(0xFFFF453A), fontWeight = FontWeight.Bold) }
}

// MARK: Moving and trimming in the lanes (iOS: hold and slide to move, drag the ends to trim)

enum class LaneDrag { move, head, tail }

/** A layer moved or trimmed by `dt` seconds from where it was when the drag began. */
fun EditorModel.dragOverlay(id: UUID, mode: LaneDrag, dt: Double) = laneDragChanged { p ->
    val i = p.overlays.indexOfFirst { it.id == id }.takeIf { it >= 0 } ?: return@laneDragChanged p
    val o = p.overlays[i]
    val total = p.duration
    val n = when (mode) {
        LaneDrag.move -> o.copy(start = (o.start + dt).coerceIn(0.0, maxOf(0.0, total - o.duration)))
        LaneDrag.head -> {
            val s = (o.start + dt).coerceIn(0.0, o.end - 0.2)
            o.copy(start = s, duration = o.end - s)
        }
        LaneDrag.tail -> o.copy(duration = (o.duration + dt).coerceIn(0.2, maxOf(0.2, total - o.start)))
    }
    p.copy(overlays = p.overlays.toMutableList().also { it[i] = n })
}

/** A sound moved or trimmed; trimming its start trims into the file (its in point follows). */
fun EditorModel.dragAudio(id: UUID, mode: LaneDrag, dt: Double) = laneDragChanged { p ->
    val i = p.audio.indexOfFirst { it.id == id }.takeIf { it >= 0 } ?: return@laneDragChanged p
    val a = p.audio[i]
    val n = when (mode) {
        LaneDrag.move -> a.copy(start = maxOf(0.0, a.start + dt))
        LaneDrag.head -> {
            val shift = dt.coerceIn(-a.inPoint / a.speed, a.duration - 0.2).coerceAtLeast(-a.start)
            a.copy(start = a.start + shift, duration = a.duration - shift, inPoint = a.inPoint + shift * a.speed)
        }
        LaneDrag.tail -> {
            val most = (a.sourceDuration - a.inPoint) / a.speed
            a.copy(duration = (a.duration + dt).coerceIn(0.2, most))
        }
    }
    p.copy(audio = p.audio.toMutableList().also { it[i] = n })
}

/** The quick colors (iOS ColorControl's swatch row); the full color menu comes later. */
private val swatches = listOf(
    cz.krechler.bombocut.model.RGBA.white, cz.krechler.bombocut.model.RGBA.black, cz.krechler.bombocut.model.RGBA.lime,
    cz.krechler.bombocut.model.RGBA(1.0, 0.84, 0.0), cz.krechler.bombocut.model.RGBA(1.0, 0.27, 0.23),
    cz.krechler.bombocut.model.RGBA(0.04, 0.52, 1.0), cz.krechler.bombocut.model.RGBA(1.0, 0.18, 0.57),
    cz.krechler.bombocut.model.RGBA(1.0, 0.58, 0.0),
)

@Composable
private fun Swatches(current: cz.krechler.bombocut.model.RGBA, pick: (cz.krechler.bombocut.model.RGBA) -> Unit) {
    Row(horizontalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(10.dp)) {
        for (c in swatches) {
            val on = c.near(current)
            androidx.compose.foundation.layout.Box(
                Modifier.size(32.dp)
                    .background(Color(c.r.toFloat(), c.g.toFloat(), c.b.toFloat()), androidx.compose.foundation.shape.CircleShape)
                    .border(if (on) 3.dp else 1.dp, if (on) Theme.accent else Color.White.copy(alpha = 0.2f), androidx.compose.foundation.shape.CircleShape)
                    .clickable { pick(c) },
            )
        }
    }
}

@Composable
fun CaptionLineSheet(model: EditorModel) {
    val (k, id) = model.selectedCue ?: return
    val cue = model.selectedCueLine ?: return
    var text by remember(id) { mutableStateOf(cue.text) }
    OutlinedTextField(
        text, { text = it; model.setCueText(k, id, it) },
        Modifier.fillMaxWidth(),
        colors = OutlinedTextFieldDefaults.colors(focusedTextColor = Color.White, unfocusedTextColor = Color.White,
                                                  focusedBorderColor = Theme.accent, cursorColor = Theme.accent),
    )
    Text(Fmt.cFixed(cue.start, 1) + " s  -  " + Fmt.cFixed(cue.end, 1) + " s", color = Theme.muted, fontWeight = FontWeight.Bold)
    TextButton({ model.deleteCue(k, id) }) { Text(loc("Delete"), color = Color(0xFFFF453A), fontWeight = FontWeight.Bold) }
    CaptionStyleControls(model, k)
}

/** The look of a whole captions track (iOS: Captions > Style). Lines and characters per line come later (they cut
 *  the lines again, which needs the cutter on Android). */
fun EditorModel.setCaptionStyle(track: Int, change: (cz.krechler.bombocut.model.CaptionStyle) -> cz.krechler.bombocut.model.CaptionStyle) = mutate { p ->
    val tracks = p.captionTracks.toMutableList()
    val caps = tracks.getOrNull(track) ?: return@mutate p
    val n = change(caps.style)
    if (n == caps.style) return@mutate p
    tracks[track] = caps.copy(style = n)
    p.copy(captionTracks = tracks)
}

/** Lines and length cut the lines again from the words (your edits kept, like iOS restyle). */
fun EditorModel.recutCaptions(track: Int, lines: Int, maxChars: Int) = mutate { p ->
    val tracks = p.captionTracks.toMutableList()
    val caps = tracks.getOrNull(track) ?: return@mutate p
    if (caps.style.lines == lines && caps.style.maxChars == maxChars) return@mutate p
    tracks[track] = caps.restyled { it.copy(lines = lines, maxChars = maxChars) }
    p.copy(captionTracks = tracks)
}

@Composable
private fun CaptionStyleControls(model: EditorModel, k: Int) {
    val st = model.project.captionTracks.getOrNull(k)?.style ?: return
    Text(loc("Style"), color = Color.White, fontWeight = FontWeight.Black)
    // 1 or 2 lines and the characters per line in one row (like iOS Layout)
    Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
        horizontalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(8.dp)) {
        for (n in 1..2) {
            val on = st.lines == n
            Text(loc(if (n == 1) "1 line" else "2 lines"), color = if (on) Color.Black else Color.White, fontWeight = FontWeight.Bold,
                 modifier = Modifier.background(if (on) Theme.accent else Theme.panel2, androidx.compose.foundation.shape.RoundedCornerShape(50))
                     .clickable { model.recutCaptions(k, n, st.maxChars) }
                     .padding(horizontal = 14.dp, vertical = 8.dp))
        }
        androidx.compose.foundation.layout.Spacer(Modifier.weight(1f))
        Text("-", color = Color.White, fontWeight = FontWeight.Black,
             modifier = Modifier.background(Theme.panel2, androidx.compose.foundation.shape.CircleShape)
                 .clickable { model.recutCaptions(k, st.lines, maxOf(8, st.maxChars - 2)) }.padding(horizontal = 14.dp, vertical = 6.dp))
        Text("${st.maxChars}", color = Color.White, fontWeight = FontWeight.Black)
        Text("+", color = Color.White, fontWeight = FontWeight.Black,
             modifier = Modifier.background(Theme.panel2, androidx.compose.foundation.shape.CircleShape)
                 .clickable { model.recutCaptions(k, st.lines, minOf(48, st.maxChars + 2)) }.padding(horizontal = 14.dp, vertical = 6.dp))
    }
    var size by remember(k, st.size) { mutableStateOf(st.size) }
    Row {
        Text(loc("Size"), color = Theme.muted, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
        Text("${(size * 1000).toInt()}", color = Color.White, fontWeight = FontWeight.Bold)
    }
    BSlider(size, 0.03..0.16, { size = it }, { model.setCaptionStyle(k) { it.copy(size = size) } })
    var y by remember(k, st.y) { mutableStateOf(st.y) }
    Row {
        Text(loc("Position"), color = Theme.muted, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
        Text("${(y * 100).toInt()} %", color = Color.White, fontWeight = FontWeight.Bold)
    }
    BSlider(y, 0.05..0.95, { y = it }, { model.setCaptionStyle(k) { it.copy(y = y) } })
    FontPills(st.font) { f -> model.setCaptionStyle(k) { it.copy(font = f, fontName = null) } }
    Text(loc("Color"), color = Theme.muted, fontWeight = FontWeight.Bold)
    Swatches(st.text) { c -> model.setCaptionStyle(k) { it.copy(text = c) } }
    var outline by remember(k, st.strokeWidth) { mutableStateOf(st.strokeWidth) }
    Row {
        Text(loc("Outline"), color = Theme.muted, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
        Text("${(outline * 100).toInt()}", color = Color.White, fontWeight = FontWeight.Bold)
    }
    BSlider(outline, 0.0..1.0, { outline = it }, { model.setCaptionStyle(k) { it.copy(strokeWidth = outline) } })
    OnOffRow("Shadow", isOn = st.shadow) { on -> model.setCaptionStyle(k) { it.copy(shadow = on) } }
    OnOffRow("Box", isOn = st.box) { on -> model.setCaptionStyle(k) { it.copy(box = on) } }
    OnOffRow("CAPS", isOn = st.caps) { on -> model.setCaptionStyle(k) { it.copy(caps = on) } }
    Text(loc("Animation"), color = Theme.muted, fontWeight = FontWeight.Bold)
    Row(horizontalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(8.dp)) {
        // the ones Android draws today (Highlight and Word by word need per-word drawing)
        for ((a, name) in listOf(cz.krechler.bombocut.model.CaptionAnim.none to "None", cz.krechler.bombocut.model.CaptionAnim.fade to "Fade",
                                 cz.krechler.bombocut.model.CaptionAnim.pop to "Pop", cz.krechler.bombocut.model.CaptionAnim.slide to "Slide up")) {
            val on = st.anim == a
            Text(loc(name), color = if (on) Color.Black else Color.White, fontWeight = FontWeight.Bold,
                 modifier = Modifier.background(if (on) Theme.accent else Theme.panel2, androidx.compose.foundation.shape.RoundedCornerShape(50))
                     .clickable { model.setCaptionStyle(k) { it.copy(anim = a) } }
                     .padding(horizontal = 14.dp, vertical = 8.dp))
        }
    }
}

/** The phone's own fonts (iOS FontPicker.builtIn, named for what they are on Android). */
private val fontChoices = listOf(
    cz.krechler.bombocut.model.CaptionFont.heavy to "System", cz.krechler.bombocut.model.CaptionFont.rounded to "Rounded",
    cz.krechler.bombocut.model.CaptionFont.condensed to "Condensed", cz.krechler.bombocut.model.CaptionFont.serif to "Serif",
    cz.krechler.bombocut.model.CaptionFont.typewriter to "Typewriter", cz.krechler.bombocut.model.CaptionFont.mono to "Mono",
)

@Composable
fun FontPills(current: cz.krechler.bombocut.model.CaptionFont, pick: (cz.krechler.bombocut.model.CaptionFont) -> Unit) {
    Text(loc("Font"), color = Theme.muted, fontWeight = FontWeight.Bold)
    Row(Modifier.horizontalScroll(androidx.compose.foundation.rememberScrollState()),
        horizontalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(8.dp)) {
        for ((f, name) in fontChoices) {
            val on = f == current
            Text(loc(name), color = if (on) Color.Black else Color.White, fontWeight = FontWeight.Bold,
                 fontFamily = androidx.compose.ui.text.font.FontFamily(cz.krechler.bombocut.engine.TextRenderer.typeface(f)),
                 modifier = Modifier.background(if (on) Theme.accent else Theme.panel2, androidx.compose.foundation.shape.RoundedCornerShape(50))
                     .clickable { pick(f) }
                     .padding(horizontal = 14.dp, vertical = 8.dp))
        }
    }
}
