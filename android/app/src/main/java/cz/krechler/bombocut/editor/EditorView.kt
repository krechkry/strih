// Part port of Bombocut/Editor/EditorView.swift (iOS ad3827a): top bar with undo / redo, preview, transport,
// the timeline and the clip toolbar (Split, Delete, Duplicate). Panels come next.
package cz.krechler.bombocut.editor

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Redo
import androidx.compose.material.icons.automirrored.filled.Undo
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.ContentCut
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import cz.krechler.bombocut.app.Fmt
import cz.krechler.bombocut.app.Theme
import cz.krechler.bombocut.app.loc
import cz.krechler.bombocut.model.Project
import cz.krechler.bombocut.model.ProjectStore

@Composable
fun EditorView(start: Project, store: ProjectStore, exportOnly: Boolean = false, close: () -> Unit) {
    BackHandler(onBack = close)
    val model = remember(start.id) { EditorModel(start, store) }
    val preview = remember(start.id) { PreviewState() }
    val tl = remember { TimelineState() }
    var exporting by remember { mutableStateOf(false) }
    var sheet by remember { mutableStateOf<String?>(null) }
    // while playing the playhead follows the player
    LaunchedEffect(preview.time, preview.playing) { if (preview.playing) model.currentTime = preview.time }

    fun scrub(t: Double) {
        preview.player?.pause()
        model.currentTime = t
        preview.seek(t)
    }

    androidx.compose.foundation.layout.Box(Modifier.fillMaxSize()) {
    Column(Modifier.fillMaxSize().background(Theme.bg).safeDrawingPadding()) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            TextButton(close) { Text(loc("Projects"), color = Theme.accent) }
            Spacer(Modifier.weight(1f))
            if (!exportOnly) IconButton({ model.undo() }, enabled = model.canUndo) {
                Icon(Icons.AutoMirrored.Filled.Undo, loc("Undo"), tint = if (model.canUndo) Color.White else Theme.muted)
            }
            if (!exportOnly) IconButton({ model.redo() }, enabled = model.canRedo) {
                Icon(Icons.AutoMirrored.Filled.Redo, loc("Redo"), tint = if (model.canRedo) Color.White else Theme.muted)
            }
            TextButton({ preview.player?.pause(); exporting = true },
                Modifier.background(Theme.accent, androidx.compose.foundation.shape.RoundedCornerShape(50))) {
                Text(loc("Export"), color = Color.Black, fontWeight = FontWeight.Bold)
            }
        }
        PreviewView(model.project, preview, Modifier.fillMaxWidth().weight(1f))
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(Fmt.time(model.currentTime) + " / " + Fmt.time(model.duration), color = Color.White, fontSize = 14.sp,
                 modifier = Modifier.weight(1f))
            IconButton({ preview.toggle() }, Modifier.size(48.dp)) {
                Icon(if (preview.playing) Icons.Filled.Pause else Icons.Filled.PlayArrow, if (preview.playing) "Pause" else "Play", tint = Color.White)
            }
            Spacer(Modifier.weight(1f))
        }
        TimelineView(model, tl, ::scrub)
        // the free week is over: the project can still be exported as it is, the tools wait for the purchase
        if (exportOnly) Text(loc("Your 7 free days are over"), color = Theme.muted, fontWeight = FontWeight.Bold,
                             modifier = Modifier.padding(horizontal = 16.dp, vertical = 24.dp))
        else ToolRow(model) { preview.player?.pause(); sheet = it }
        preview.error?.let { Text(it, color = Color(0xFFFF453A), modifier = Modifier.padding(12.dp)) }
    }
    // a panel covers the bottom, the preview stays in view (iOS Panel)
    val open = sheet
    if (open != null && model.selectedIndex != null) {
        androidx.compose.foundation.layout.Box(Modifier.fillMaxSize().safeDrawingPadding(), contentAlignment = Alignment.BottomCenter) {
            Panel(when (open) { "speed" -> 560.dp; "adjust" -> 520.dp; else -> 380.dp }, close = { sheet = null }) {
                when (open) {
                    "adjust" -> AdjustSheet(model)
                    "speed" -> SpeedSheet(model, ::scrub)
                    "volume" -> VolumeSheet(model)
                }
            }
        }
    }
    if (exporting) ExportSheet(model.project) { exporting = false }
    }
}

@Composable
private fun ToolRow(model: EditorModel, open: (String) -> Unit) {
    Row(
        Modifier.fillMaxWidth().height(72.dp).horizontalScroll(rememberScrollState()).padding(horizontal = 10.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        ToolButton(Icons.Filled.ContentCut, "Split") { model.split() }
        if (model.selectedIndex != null) {
            ToolButton(Icons.Filled.Tune, "Adjust") { open("adjust") }
            ToolButton(Icons.Filled.Speed, "Speed") { open("speed") }
            ToolButton(Icons.AutoMirrored.Filled.VolumeUp, "Volume") { open("volume") }
            ToolButton(Icons.Filled.ContentCopy, "Duplicate") { model.duplicateSelected() }
            ToolButton(Icons.Filled.Delete, "Delete") { model.deleteSelected() }
        }
    }
}

/** Bombocut's ToolButton: icon over a small label, 66 x 60. */
@Composable
fun ToolButton(icon: ImageVector, label: String, tint: Color = Color.White, action: () -> Unit) {
    TextButton(action, Modifier.width(66.dp).height(64.dp)) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Icon(icon, null, tint = tint, modifier = Modifier.size(22.dp))
            Text(loc(label), color = tint, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center, maxLines = 2)
        }
    }
}
