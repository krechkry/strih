// Stand-in for Bombocut/Editor/EditorView.swift until the editor port (plan hours 13 to 18).
package cz.krechler.bombocut.editor

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import cz.krechler.bombocut.app.Fmt
import cz.krechler.bombocut.app.Theme
import cz.krechler.bombocut.app.loc
import cz.krechler.bombocut.app.locf
import cz.krechler.bombocut.model.Project

@Composable
fun EditorView(project: Project, close: () -> Unit) {
    BackHandler(onBack = close)
    Column(Modifier.fillMaxSize().background(Theme.bg).safeDrawingPadding().padding(16.dp)) {
        TextButton(close) { Text(loc("Projects"), color = Theme.accent) }
        Text(project.name, color = Color.White, fontSize = 22.sp, fontWeight = FontWeight.Bold)
        Text(Fmt.duration(project.duration) + " · " + locf(if (project.clips.size == 1) "%lld clip" else "%lld clips", project.clips.size) +
             " · " + project.canvas.label, color = Theme.muted)
    }
}
