// Ported from Bombocut/Home/HomeView.swift (iOS ad3827a): the projects list, New project, sorting, rename, delete.
// Not yet: iCloud rows / sync badges (iPhone only), share / open .bbc, the trial pill, the import ball game.
package cz.krechler.bombocut.home

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Storage
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.filled.Sort
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import cz.krechler.bombocut.app.Fmt
import cz.krechler.bombocut.app.Theme
import cz.krechler.bombocut.app.loc
import cz.krechler.bombocut.app.locf
import cz.krechler.bombocut.engine.ThumbnailCache
import cz.krechler.bombocut.model.Clip
import cz.krechler.bombocut.model.Media
import cz.krechler.bombocut.model.Paths
import cz.krechler.bombocut.model.Project
import cz.krechler.bombocut.model.ProjectStore
import kotlinx.coroutines.launch
import java.util.UUID

/** How Home lists the projects (the menu next to PROJECTS). */
enum class ProjectSort(val raw: String, val title: String) {
    // iOS raw values (name, size, modified, created); `name` can't be a Kotlin enum entry
    byName("name", "Name"), size("size", "Size"), modified("modified", "Last modified"), created("created", "Date created");

    fun sorted(projects: List<Project>): List<Project> = when (this) {
        byName -> projects.sortedWith { a, b -> java.text.Collator.getInstance().compare(a.name, b.name) }
        size -> { val s = projects.associate { it.id to bytes(it) }; projects.sortedByDescending { s[it.id] ?: 0 } }
        modified -> projects.sortedByDescending { it.modified }
        created -> projects.sortedByDescending { it.created }
    }

    companion object {
        /** Space the project's videos take here (a video used twice counts once). */
        fun bytes(p: Project): Long = p.mediaFiles.sumOf { Paths.mediaFile(it).length() }
    }
}

@Composable
fun HomeView(store: ProjectStore, open: (UUID) -> Unit) {
    val projects by store.projects.collectAsState()
    var sort by remember { mutableStateOf(ProjectSort.modified) }
    var renaming by remember { mutableStateOf<Project?>(null) }
    var deleting by remember { mutableStateOf<Project?>(null) }
    var importing by remember { mutableStateOf<String?>(null) }
    var showStorage by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val context = LocalContext.current

    /** Picked videos in the order they were picked become a new project (iOS: makeClips, canvas, name). */
    fun create(uris: List<Uri>) {
        if (uris.isEmpty()) return
        scope.launch {
            val clips = mutableListOf<Clip>()
            var firstW: Int? = null; var firstH: Int? = null
            for ((n, u) in uris.withIndex()) {
                importing = locf("Importing %lld of %lld", n + 1, uris.size)
                val f = Media.copyIn(context, u) ?: continue
                val made = Media.videoClip(f)
                if (made == null) { f.delete(); continue }
                if (firstW == null) { firstW = made.second.width; firstH = made.second.height }
                clips += made.first
            }
            importing = null
            if (clips.isEmpty()) return@launch
            val p = Project(name = store.nextName(), canvas = Media.canvas(firstW, firstH), clips = clips)
            store.save(p)
            open(p.id)
        }
    }

    val photos = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia()) { create(it) }
    val files = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { create(it) }
    // a .bbc from an iPhone (or another Android): the project with its clips
    val bbc = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) scope.launch {
            importing = loc("Copying into BOMBOCUT…")
            val r = cz.krechler.bombocut.model.ProjectFile.open(context, uri, store)
            importing = null
            when (r) {
                is cz.krechler.bombocut.model.ProjectFile.Result.Opened -> {
                    if (r.missing > 0) importing = locf("%lld videos weren't in the file.", r.missing)
                    open(r.project.id)
                }
                cz.krechler.bombocut.model.ProjectFile.Result.NotAProject -> importing = loc("This file isn't a BOMBOCUT project.")
                cz.krechler.bombocut.model.ProjectFile.Result.NewerFormat -> importing = loc("This project comes from a newer BOMBOCUT. Update the app and open it again.")
            }
        }
    }

    Column(Modifier.fillMaxSize().background(Theme.bg).safeDrawingPadding()) {
        Box(Modifier.fillMaxWidth().padding(vertical = 12.dp), contentAlignment = Alignment.Center) {
            Text("BOMBOCUT", color = Color.White, fontSize = 22.sp, fontWeight = FontWeight.Black)
            // iOS: the drive icon in the home toolbar
            androidx.compose.material3.IconButton({ showStorage = true }, Modifier.align(Alignment.CenterEnd).padding(end = 8.dp)) {
                androidx.compose.material3.Icon(Icons.Filled.Storage, loc("Storage"), tint = Color.White)
            }
        }
        LazyColumn(
            Modifier.fillMaxSize().padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            item {
                NewProjectCard(
                    onPhotos = { photos.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.VideoOnly)) },
                    onFiles = { files.launch(arrayOf("video/*")) },
                    status = importing,
                )
            }
            item {
                TextButton({ bbc.launch(arrayOf("*/*")) }, Modifier.fillMaxWidth()) {
                    Text(loc("Open a project file (.bbc)"), color = Color.White.copy(alpha = 0.85f), fontWeight = FontWeight.SemiBold)
                }
            }
            if (projects.isNotEmpty()) item { ProjectsHeader(sort) { sort = it } }
            items(sort.sorted(projects), key = { it.id }) { p ->
                ProjectRow(p, onOpen = { open(p.id) }, onRename = { renaming = p }, onDelete = { deleting = p },
                           onShare = {
                               scope.launch {
                                   importing = loc("Packing your project…")
                                   val f = cz.krechler.bombocut.model.ProjectFile.write(context, p)
                                   importing = null
                                   cz.krechler.bombocut.model.ProjectFile.share(context, f)
                               }
                           })
            }
            item { Spacer(Modifier.size(24.dp)) }
        }
    }

    if (showStorage) StorageView { showStorage = false }
    renaming?.let { p ->
        var text by remember(p.id) { mutableStateOf(p.name) }
        AlertDialog(
            onDismissRequest = { renaming = null },
            title = { Text(loc("Rename")) },
            text = { OutlinedTextField(text, { text = it }, singleLine = true) },
            confirmButton = { TextButton({ store.rename(p, text.trim().ifEmpty { p.name }); renaming = null }) { Text(loc("Save")) } },
            dismissButton = { TextButton({ renaming = null }) { Text(loc("Cancel")) } },
        )
    }
    deleting?.let { p ->
        AlertDialog(
            onDismissRequest = { deleting = null },
            title = { Text(p.name) },
            text = { Text(loc("It disappears forever, together with its imported videos. There is no trash bin. Your originals in the gallery stay.")) },
            confirmButton = { TextButton({ store.delete(p); deleting = null }) { Text(loc("Delete forever"), color = Color(0xFFFF453A)) } },
            dismissButton = { TextButton({ deleting = null }) { Text(loc("Cancel")) } },
        )
    }
}

@Composable
private fun NewProjectCard(onPhotos: () -> Unit, onFiles: () -> Unit, status: String?) {
    val shape = RoundedCornerShape(18.dp)
    Column(
        Modifier.fillMaxWidth().background(Theme.panel, shape).border(1.dp, Theme.line, shape).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Text(loc("New project"), color = Color.White, fontSize = 20.sp, fontWeight = FontWeight.SemiBold)
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            BigButton(loc("Photos"), Theme.accent, Color.Black, Modifier.weight(1f), onPhotos)
            BigButton(loc("Files"), Theme.panel2, Color.White, Modifier.weight(1f), onFiles)
        }
        Text(status ?: loc("Pick clips in the order you want them. Original quality is kept."),
             color = if (status != null) Theme.accent else Theme.muted, fontSize = 13.sp)
    }
}

@Composable
private fun BigButton(title: String, bg: Color, fg: Color, modifier: Modifier, action: () -> Unit) {
    TextButton(
        onClick = action,
        modifier = modifier.heightIn(min = 50.dp).background(bg, RoundedCornerShape(12.dp)),
    ) { Text(title, color = fg, fontWeight = FontWeight.SemiBold, fontSize = 17.sp) }
}

@Composable
private fun ProjectsHeader(sort: ProjectSort, set: (ProjectSort) -> Unit) {
    var menu by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth().padding(top = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(loc("Projects").uppercase(), color = Theme.muted, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.weight(1f))
        Box {
            IconButton({ menu = true }, Modifier.size(32.dp)) {
                Icon(Icons.AutoMirrored.Filled.Sort, loc("Sort by"), tint = Theme.muted)
            }
            DropdownMenu(menu, { menu = false }) {
                ProjectSort.entries.forEach { o ->
                    DropdownMenuItem(text = { Text((if (o == sort) "✓ " else "") + loc(o.title)) }, onClick = { set(o); menu = false })
                }
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ProjectRow(p: Project, onOpen: () -> Unit, onRename: () -> Unit, onDelete: () -> Unit, onShare: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    var thumb by remember(p.id) { mutableStateOf<ImageBitmap?>(null) }
    val first = p.clips.firstOrNull()
    LaunchedEffect(first?.mediaFile, first?.inPoint) {
        thumb = first?.let { ThumbnailCache.image(it.mediaFile, it.inPoint + 0.3)?.asImageBitmap() }
    }
    val size = android.text.format.Formatter.formatShortFileSize(LocalContext.current, ProjectSort.bytes(p))
    val shape = RoundedCornerShape(14.dp)
    Box {
        Row(
            Modifier.fillMaxWidth().clip(shape).background(Theme.panel)
                .combinedClickable(onClick = onOpen, onLongClick = { menu = true })
                .padding(10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Box(Modifier.size(56.dp, 72.dp).clip(RoundedCornerShape(8.dp)).background(Theme.panel2)) {
                thumb?.let { Image(it, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop) }
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(p.name, color = Color.White, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(Fmt.duration(p.duration), color = Color.White.copy(alpha = 0.85f), fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                Text(locf(if (p.clips.size == 1) "%lld clip" else "%lld clips", p.clips.size) + " · " + size,
                     color = Theme.muted, fontSize = 13.sp)
            }
            Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = Theme.muted)
        }
        DropdownMenu(menu, { menu = false }) {
            DropdownMenuItem(text = { Text(loc("Rename")) }, onClick = { menu = false; onRename() })
            DropdownMenuItem(text = { Text(loc("Share project")) }, onClick = { menu = false; onShare() })
            DropdownMenuItem(text = { Text(loc("Delete"), color = Color(0xFFFF453A)) }, onClick = { menu = false; onDelete() })
        }
    }
}
