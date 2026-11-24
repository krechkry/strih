// Stand-in for Bombocut/Editor/EditorView.swift: preview and transport so far (editor port: plan hours 13 to 18).
package cz.krechler.bombocut.editor

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import cz.krechler.bombocut.app.Fmt
import cz.krechler.bombocut.app.Theme
import cz.krechler.bombocut.app.loc
import cz.krechler.bombocut.model.Project

@Composable
fun EditorView(project: Project, close: () -> Unit) {
    BackHandler(onBack = close)
    val preview = remember(project.id) { PreviewState() }
    Column(Modifier.fillMaxSize().background(Theme.bg).safeDrawingPadding()) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            TextButton(close) { Text(loc("Projects"), color = Theme.accent) }
            Text(project.name, color = Color.White, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f), maxLines = 1)
        }
        PreviewView(project, preview, Modifier.fillMaxWidth().weight(1f))
        Row(
            Modifier.fillMaxWidth().padding(12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.Center,
        ) {
            Text(Fmt.time(preview.time) + " / " + Fmt.time(project.duration), color = Color.White, fontSize = 14.sp)
            IconButton({ preview.toggle() }, Modifier.size(48.dp)) {
                Icon(if (preview.playing) Icons.Filled.Pause else Icons.Filled.PlayArrow, if (preview.playing) "Pause" else "Play", tint = Color.White)
            }
        }
        preview.error?.let { Text(it, color = Color(0xFFFF453A), modifier = Modifier.padding(12.dp)) }
    }
}
