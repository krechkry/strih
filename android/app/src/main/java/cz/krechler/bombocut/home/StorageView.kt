// Stand-in for Bombocut/Home/StorageView.swift: everything BOMBOCUT keeps on the phone, with a way to delete each
// part. Android has fewer parts so far: temporary files, the speech model (download / pause / resume / delete, asked
// first on mobile data), and what is kept (videos in projects, project files).
package cz.krechler.bombocut.home

import android.text.format.Formatter
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDownward
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Movie
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.AlertDialog
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import cz.krechler.bombocut.app.Theme
import cz.krechler.bombocut.app.loc
import cz.krechler.bombocut.app.locf
import cz.krechler.bombocut.engine.SpeechDownload
import cz.krechler.bombocut.engine.SpeechModel
import cz.krechler.bombocut.model.Paths
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

/** Sizes of what BOMBOCUT keeps (iOS StorageReport). */
data class StorageReport(val temp: Long = 0, val model: Long = 0, val media: Long = 0, val projects: Long = 0, val total: Long = 0) {
    companion object {
        fun size(f: File?): Long = if (f == null || !f.exists()) 0 else if (f.isFile) f.length() else f.listFiles()?.sumOf { size(it) } ?: 0

        fun make(context: android.content.Context): StorageReport {
            val temp = size(context.cacheDir)
            val model = size(SpeechModel.folder.parentFile)
            val media = size(Paths.media)
            val projects = size(Paths.projects)
            val total = size(context.filesDir) + temp + size(context.noBackupFilesDir)
            return StorageReport(temp, model, media, projects, total)
        }
    }
}

@Composable
fun StorageView(onDone: () -> Unit) {
    val context = LocalContext.current
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    var report by remember { mutableStateOf(StorageReport()) }
    var confirm by remember { mutableStateOf<String?>(null) }
    var askCellular by remember { mutableStateOf(false) }
    val download = SpeechDownload.state
    val running = download is SpeechDownload.State.Downloading
    fun size(b: Long) = Formatter.formatShortFileSize(context, b)
    // again whenever the model's state moves on (and every few seconds while it downloads)
    LaunchedEffect(download) { report = withContext(Dispatchers.IO) { StorageReport.make(context) } }

    Dialog(onDone, DialogProperties(usePlatformDefaultWidth = false)) {
        Column(Modifier.fillMaxSize().background(Theme.bg).safeDrawingPadding()) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                Spacer(Modifier.width(64.dp))
                Text(loc("Storage"), color = Color.White, fontWeight = FontWeight.Black, fontSize = 18.sp,
                     modifier = Modifier.weight(1f), textAlign = androidx.compose.ui.text.style.TextAlign.Center)
                TextButton(onDone, Modifier.width(64.dp)) { Text(loc("Done"), color = Theme.accent, fontWeight = FontWeight.Bold) }
            }
            Column(Modifier.verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(22.dp)) {
                Column {
                    Text(loc("BOMBOCUT uses"), color = Theme.muted, fontWeight = FontWeight.Bold)
                    Text(size(report.total), color = Color.White, fontWeight = FontWeight.Black, fontSize = 40.sp)
                }
                Section(loc("Clean up")) {
                    StorageRow(Icons.Filled.History, loc("Temporary files"), loc("Old exports, caption audio, imports in progress"),
                               size(report.temp), onDelete = if (report.temp > 0) ({ confirm = "temp" }) else null)
                }
                Section(loc("AI Models")) {
                    val detail = when (download) {
                        SpeechDownload.State.Ready -> loc("Downloaded")
                        is SpeechDownload.State.Downloading -> locf("Downloading %lld %%", (download.fraction * 100).toInt())
                        is SpeechDownload.State.Paused -> locf("Paused at %lld %%", (download.fraction * 100).toInt())
                        is SpeechDownload.State.Failed -> loc("Download failed. Tap to try again, it continues where it stopped.")
                        SpeechDownload.State.Missing -> locf("Not downloaded (%@)", loc("about 650 MB"))
                    }
                    val action: Pair<ImageVector, () -> Unit>? = when (download) {
                        SpeechDownload.State.Ready -> null
                        is SpeechDownload.State.Downloading -> Icons.Filled.Pause to { SpeechDownload.pause() }
                        is SpeechDownload.State.Paused -> Icons.Filled.PlayArrow to { SpeechDownload.start() }
                        else -> Icons.Filled.ArrowDownward to {
                            if (SpeechDownload.onMobileData(context)) { askCellular = true } else { SpeechDownload.start() }
                        }
                    }
                    StorageRow(Icons.Filled.GraphicEq, loc("Automatic Captions"), detail,
                               if (download == SpeechDownload.State.Ready) size(report.model) else null,
                               action = action, green = true,
                               onDelete = if (!running && report.model > 0) ({ confirm = "model" }) else null)
                }
                Section(loc("Kept")) {
                    StorageRow(Icons.Filled.Movie, loc("Videos in your projects"), null, size(report.media))
                    StorageRow(Icons.Filled.Description, loc("Project files"), null, size(report.projects))
                }
                Text(loc("Your originals in the gallery are never touched. Deleting here is permanent, there is no trash bin."),
                     color = Theme.muted, fontWeight = FontWeight.SemiBold)
            }
        }
    }

    confirm?.let { what ->
        AlertDialog(
            onDismissRequest = { confirm = null },
            title = { Text(if (what == "model") locf("Delete the %@ model?", loc("Automatic Captions")) else loc("Delete temporary files?")) },
            text = { Text(loc("This can't be undone.")) },
            confirmButton = {
                TextButton({
                    confirm = null
                    scope.launch {
                        if (what == "model") SpeechDownload.delete()
                        else withContext(Dispatchers.IO) { context.cacheDir.listFiles()?.forEach { it.deleteRecursively() } }
                        kotlinx.coroutines.delay(300)
                        report = withContext(Dispatchers.IO) { StorageReport.make(context) }
                    }
                }) { Text(loc("Delete"), color = Color(0xFFFF453A)) }
            },
            dismissButton = { TextButton({ confirm = null }) { Text(loc("Cancel")) } },
        )
    }
    if (askCellular) AlertDialog(
        onDismissRequest = { askCellular = false },
        title = { Text(loc("Download on mobile data?")) },
        text = { Text(loc("The speech model is about 650 MB. Wi-Fi is better.")) },
        confirmButton = { TextButton({ askCellular = false; SpeechDownload.start() }) { Text(loc("Download anyway")) } },
        dismissButton = { TextButton({ askCellular = false }) { Text(loc("Cancel")) } },
    )
}

@Composable
private fun Section(title: String, content: @Composable () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(title.uppercase(), color = Theme.muted, fontWeight = FontWeight.SemiBold, fontSize = 13.sp)
        content()
    }
}

/** `green`: the AI models, a dim lime tint (space well spent, not junk). */
@Composable
private fun StorageRow(icon: ImageVector, title: String, detail: String?, bytes: String?,
                       action: Pair<ImageVector, () -> Unit>? = null, green: Boolean = false, onDelete: (() -> Unit)? = null) {
    Row(Modifier.fillMaxWidth().background(if (green) Theme.accent.copy(alpha = 0.08f) else Theme.panel, RoundedCornerShape(12.dp))
            .padding(12.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Icon(icon, null, tint = Color.White, modifier = Modifier.size(24.dp))
        Column(Modifier.weight(1f)) {
            Text(title, color = Color.White, fontWeight = FontWeight.Bold)
            if (detail != null) Text(detail, color = Theme.muted, fontWeight = FontWeight.SemiBold, fontSize = 13.sp)
        }
        if (bytes != null) Text(bytes, color = Color.White, fontWeight = FontWeight.Bold)
        action?.let { (ic, go) ->
            val start = ic == Icons.Filled.ArrowDownward || ic == Icons.Filled.PlayArrow
            Box(Modifier.size(36.dp).background(if (start) Theme.accent else Theme.panel2, CircleShape), contentAlignment = Alignment.Center) {
                IconButton(go) {
                    Icon(ic, loc(when (ic) {
                        Icons.Filled.Pause -> "Pause download"
                        Icons.Filled.PlayArrow -> "Resume download"
                        else -> "Download now"
                    }), tint = if (start) Color.Black else Color.White)
                }
            }
        }
        if (onDelete != null) Box(Modifier.size(36.dp).background(Theme.panel2, CircleShape), contentAlignment = Alignment.Center) {
            IconButton(onDelete) { Icon(Icons.Filled.Delete, loc("Delete"), tint = Color(0xFFFF453A)) }
        }
    }
}
