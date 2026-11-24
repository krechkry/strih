// Part port of Bombocut/Editor/EditorModel.swift (addText, sounds) and the text / sound panels (iOS ad3827a):
// add a text or a sound at the playhead, pick them in their lanes, change the words, size, volume, fades, delete.
// Not yet: fonts, colors, outline / shadow / box tabs, presets, keyframes, moving and trimming in the lanes.
package cz.krechler.bombocut.editor

import android.content.Context
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.provider.OpenableColumns
import androidx.compose.foundation.layout.Row
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
import java.io.File
import java.util.UUID

fun EditorModel.selectOverlay(id: UUID?) { selectedOverlayID = id; if (id != null) { selectedClipID = null; selectedAudioID = null } }
fun EditorModel.selectAudio(id: UUID?) { selectedAudioID = id; if (id != null) { selectedClipID = null; selectedOverlayID = null } }

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
