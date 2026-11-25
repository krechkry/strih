// Ported from Bombocut/Model/Storage.swift (iOS ad3827a): Paths, ProjectStore, Media.
// Same folder layout as iOS (Media/, Projects/<UUID>.json), same JSON.
package cz.krechler.bombocut.model

import android.content.Context
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.webkit.MimeTypeMap
import cz.krechler.bombocut.app.loc
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.withContext
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.UUID

object Paths {
    lateinit var docs: File
        private set
    val media: File get() = File(docs, "Media")
    val projects: File get() = File(docs, "Projects")

    /** A 2 s black 64 x 64 clip with silence (assets): what a video input shows where it has nothing (CompositionBuilder). */
    var filler: File? = null
        private set

    fun init(context: Context) {
        docs = context.filesDir
        ensure()
        filler = runCatching {
            File(context.noBackupFilesDir, "filler-1.mp4").also { f ->
                if (!f.exists() || f.length() == 0L) context.assets.open("filler.mp4").use { i -> f.outputStream().use { i.copyTo(it) } }
            }
        }.getOrNull()
    }

    fun ensure() { media.mkdirs(); projects.mkdirs() }
    fun mediaFile(name: String) = File(media, name)
}

/** Keeps every project as a JSON file in Projects/ (the same files iOS writes). */
class ProjectStore {
    private val _projects = MutableStateFlow<List<Project>>(emptyList())
    val projects: StateFlow<List<Project>> = _projects

    init { Paths.ensure(); load() }

    fun load() {
        val files = Paths.projects.listFiles { f -> f.extension == "json" } ?: emptyArray()
        _projects.value = files.mapNotNull { f ->
            runCatching { BomboJson.decodeFromString(Project.serializer(), f.readText()) }.getOrNull()
        }.sortedByDescending { it.modified }
    }

    fun save(p: Project) {
        val file = File(Paths.projects, p.id.toString().uppercase() + ".json")
        val tmp = File(file.path + ".tmp")
        tmp.writeText(BomboJson.encodeToString(Project.serializer(), p))
        tmp.renameTo(file)
        val list = _projects.value.toMutableList()
        val i = list.indexOfFirst { it.id == p.id }
        if (i >= 0) list[i] = p else list.add(0, p)
        _projects.value = list.sortedByDescending { it.modified }
    }

    fun delete(p: Project) {
        File(Paths.projects, p.id.toString().uppercase() + ".json").delete()
        _projects.value = _projects.value.filter { it.id != p.id }
        cleanupMedia()
    }

    fun rename(p: Project, name: String) = save(p.copy(name = name, modified = AppleDate.now()))

    /** Removes imported media no project uses any more (files from the last 10 minutes stay). */
    fun cleanupMedia() {
        val used = _projects.value.flatMap { it.mediaFiles }.toSet()
        val recent = System.currentTimeMillis() - 600_000
        Paths.media.listFiles()?.forEach { f -> if (f.name !in used && f.lastModified() < recent) f.delete() }
    }

    fun nextName(): String = loc("Project") + " " + SimpleDateFormat("d. M. HH:mm", Locale.ROOT).format(Date())

    fun project(id: UUID): Project? = _projects.value.firstOrNull { it.id == id }
}

/** What a video file is: its length and its upright size. */
data class Probe(val duration: Double, val width: Int, val height: Int)

object Media {
    /** Copies a picked file into Media/ under a unique name; returns the new file. */
    suspend fun copyIn(context: Context, uri: Uri): File? = withContext(Dispatchers.IO) {
        Paths.ensure()
        val type = context.contentResolver.getType(uri)
        val ext = (type?.let { MimeTypeMap.getSingleton().getExtensionFromMimeType(it) } ?: "mp4").lowercase()
        val dest = Paths.mediaFile(UUID.randomUUID().toString().uppercase() + "." + ext)
        runCatching {
            context.contentResolver.openInputStream(uri)!!.use { input -> dest.outputStream().use { input.copyTo(it) } }
            dest
        }.getOrElse { dest.delete(); null }
    }

    /** Length of the video and its displayed (rotated) size; null when it isn't a video we can read. */
    fun probe(file: File): Probe? = runCatching {
        val r = MediaMetadataRetriever()
        try {
            r.setDataSource(file.path)
            if (r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_VIDEO) != "yes") return null
            val ms = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toDoubleOrNull() ?: return null
            var w = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0
            var h = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0
            val rot = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
            if (rot == 90 || rot == 270) { val t = w; w = h; h = t }
            Probe(ms / 1000.0, w, h)
        } finally { r.release() }
    }.getOrNull()

    /** A video already in Media/ as a clip (Swift's `videoClip`). */
    fun videoClip(file: File): Pair<Clip, Probe>? {
        val info = probe(file) ?: return null
        if (info.duration <= 0.05) return null
        val c = Clip.new(file.name, info.duration).copy(
            aspect = if (info.height > 0) info.width.toDouble() / info.height else null,
            fill = Defaults.fillNewClips,
        )
        return c to info
    }

    /** The canvas a first clip of this size suggests (near-standard shapes snap: 1080x1920 is 9:16). */
    fun canvas(w: Int?, h: Int?): Canvas {
        if (w == null || h == null || w <= 0 || h <= 0) return Canvas()
        val g = gcd(w, h)
        var c = Canvas(w.toDouble() / g, h.toDouble() / g)
        for ((cw, ch) in listOf(9.0 to 16.0, 16.0 to 9.0, 1.0 to 1.0, 4.0 to 5.0, 4.0 to 3.0, 3.0 to 4.0)) {
            if (kotlin.math.abs(cw / ch - c.aspect) < 0.01) c = Canvas(cw, ch)
        }
        return c
    }

    private tailrec fun gcd(a: Int, b: Int): Int = if (b == 0) maxOf(a, 1) else gcd(b, a % b)
}
