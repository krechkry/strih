// Part port of Bombocut/Editor/Sheets.swift (ExportSheet): pick a preset, render, save to the gallery.
package cz.krechler.bombocut.editor

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import cz.krechler.bombocut.app.Theme
import cz.krechler.bombocut.app.fmt
import cz.krechler.bombocut.app.loc
import cz.krechler.bombocut.engine.ExportPreset
import cz.krechler.bombocut.engine.Exporter
import cz.krechler.bombocut.model.Project
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

@Composable
fun ExportSheet(project: Project, close: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var progress by remember { mutableStateOf<Double?>(null) }
    var done by remember { mutableStateOf<String?>(null) }
    var job by remember { mutableStateOf<Job?>(null) }

    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.6f)).clickable(enabled = progress == null) { close() },
        contentAlignment = Alignment.BottomCenter) {
        Column(
            Modifier.fillMaxWidth().background(Theme.panel, RoundedCornerShape(topStart = 22.dp, topEnd = 22.dp))
                .clickable(enabled = false) {}.padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(loc("Export"), color = Color.White, fontSize = 22.sp, fontWeight = FontWeight.Black)
            val p = progress
            when {
                done != null -> {
                    Text(done!!, color = Theme.accent, fontWeight = FontWeight.Bold)
                    TextButton(close) { Text(loc("Done"), color = Color.White) }
                }
                p != null -> {
                    LinearProgressIndicator({ p.toFloat() }, Modifier.fillMaxWidth(), color = Theme.accent, trackColor = Theme.panel2)
                    Text(fmt("%d %%", (p * 100).toInt()), color = Color.White)
                    TextButton({ job?.cancel(); progress = null }) { Text(loc("Cancel"), color = Theme.muted) }
                }
                else -> ExportPreset.all.forEach { preset ->
                    val (w, h) = project.canvas.size(preset.shortSide)
                    Column(
                        Modifier.fillMaxWidth().background(Theme.panel2, RoundedCornerShape(12.dp)).clickable {
                            progress = 0.0
                            job = scope.launch {
                                when (val r = Exporter.render(context, project, preset) { progress = it }) {
                                    is Exporter.Result.Saved -> {
                                        val ok = Exporter.saveToGallery(context, r.file, project.name.replace("/", "-"))
                                        done = if (ok) loc("Saved to Photos") else loc("Couldn't save the video.")
                                    }
                                    is Exporter.Result.Failed -> done = r.message
                                }
                                progress = null
                            }
                        }.padding(14.dp),
                    ) {
                        Text(loc(preset.title), color = Color.White, fontWeight = FontWeight.Bold)
                        Text("${w}x$h · " + cz.krechler.bombocut.app.Fmt.g(preset.mbps) + " Mbps", color = Theme.muted, fontSize = 13.sp)
                    }
                }
            }
        }
    }
}
