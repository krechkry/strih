// Part port of Bombocut/Model/ProjectFile.swift (iOS ad3827a): opening a .bbc project file (a plain zip:
// bombocut.json, project.json, Media/, Fonts/, LUTs/). The project lands in the list (a copy when it is already
// there), its videos in the media folder; and writing one (everything inside, format 1) to share. Not yet: fonts
// and LUTs (they stay out), light files'
// iCloud Photos videos (an iPhone-only path: those clips come in missing).
package cz.krechler.bombocut.model

import android.content.Context
import android.net.Uri
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.intOrNull
import java.io.File
import java.util.UUID
import java.util.zip.ZipInputStream

object ProjectFile {
    /** The newest format this app reads (iOS: 1 = everything inside, 2 = light). */
    const val format = 2

    sealed class Result {
        data class Opened(val project: Project, val missing: Int) : Result()
        data object NotAProject : Result()
        data object NewerFormat : Result()
    }

    @Serializable
    private data class Manifest(val format: Int, val app: String, val name: String, val made: Double,
                                val media: List<String>, val fonts: List<String>, val luts: List<String>, val bytes: Long)

    /** The project's name as a file name (iOS fileName). */
    private fun fileName(name: String): String =
        name.split('/', '\\', ':', '?', '*', '"', '<', '>', '|').joinToString(" ").trim().ifEmpty { "BOMBOCUT" }

    /**
     * The project with every video it uses, as a .bbc in the app's share folder (an iPhone opens it in BOMBOCUT).
     * Videos go in uncompressed (they are compressed already).
     */
    suspend fun write(context: Context, p: Project): File = withContext(Dispatchers.IO) {
        val dir = File(context.cacheDir, "share").apply { deleteRecursively(); mkdirs() }
        val out = File(dir, fileName(p.name) + ".bbc")
        val media = p.mediaFiles.filter { Paths.mediaFile(it).exists() }.sorted()
        val bytes = media.sumOf { Paths.mediaFile(it).length() }
        val manifest = Manifest(1, "BOMBOCUT Android", p.name, AppleDate.now(), media, emptyList(), emptyList(), bytes)
        java.util.zip.ZipOutputStream(out.outputStream().buffered()).use { zip ->
            zip.setLevel(java.util.zip.Deflater.DEFAULT_COMPRESSION)
            zip.putNextEntry(java.util.zip.ZipEntry("bombocut.json"))
            zip.write(Json.encodeToString(Manifest.serializer(), manifest).encodeToByteArray())
            zip.closeEntry()
            zip.putNextEntry(java.util.zip.ZipEntry("project.json"))
            zip.write(BomboJson.encodeToString(Project.serializer(), p).encodeToByteArray())
            zip.closeEntry()
            zip.setLevel(java.util.zip.Deflater.NO_COMPRESSION)
            for (m in media) {
                zip.putNextEntry(java.util.zip.ZipEntry("Media/$m"))
                Paths.mediaFile(m).inputStream().use { it.copyTo(zip) }
                zip.closeEntry()
            }
        }
        out
    }

    /** Hands the file to the share sheet (Nearby Share, Drive, mail, ...). */
    fun share(context: Context, file: File) {
        val uri = androidx.core.content.FileProvider.getUriForFile(context, context.packageName + ".files", file)
        val send = android.content.Intent(android.content.Intent.ACTION_SEND).apply {
            type = "application/octet-stream"
            putExtra(android.content.Intent.EXTRA_STREAM, uri)
            addFlags(android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        context.startActivity(android.content.Intent.createChooser(send, file.name).addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    /** Names the zip may put files under: no folders, no tricks. */
    private fun safeName(n: String) = n.isNotEmpty() && !n.startsWith(".") && '/' !in n && '\\' !in n && n != ".."

    suspend fun open(context: Context, uri: Uri, store: ProjectStore): Result = withContext(Dispatchers.IO) {
        Paths.ensure()
        // first pass: the two small json files (they may come after the media in the zip, so the media go to temp)
        val temp = File(context.cacheDir, "Unpack-" + UUID.randomUUID()).apply { mkdirs() }
        var manifest: String? = null
        var body: String? = null
        try {
            context.contentResolver.openInputStream(uri)?.use { raw ->
                ZipInputStream(raw.buffered()).use { zip ->
                    while (true) {
                        val e = zip.nextEntry ?: break
                        if (e.isDirectory) continue
                        when {
                            e.name == "bombocut.json" -> manifest = zip.readBytes().decodeToString()
                            e.name == "project.json" -> body = zip.readBytes().decodeToString()
                            e.name.startsWith("Media/") -> {
                                val n = e.name.removePrefix("Media/")
                                if (safeName(n)) File(temp, n).outputStream().use { zip.copyTo(it) }
                            }
                        }
                    }
                }
            } ?: return@withContext Result.NotAProject
            val head = manifest ?: return@withContext Result.NotAProject
            val f = runCatching { Json.parseToJsonElement(head).jsonObject["format"]?.jsonPrimitive?.intOrNull }.getOrNull()
                ?: return@withContext Result.NotAProject
            if (f > format) return@withContext Result.NewerFormat
            var p = runCatching { BomboJson.decodeFromString(Project.serializer(), body ?: "") }.getOrNull()
                ?: return@withContext Result.NotAProject
            // the videos the project uses and the app doesn't have yet
            for (name in p.mediaFiles) {
                val src = File(temp, name)
                val dest = Paths.mediaFile(name)
                if (src.exists() && !dest.exists()) src.renameTo(dest).let { ok -> if (!ok) src.copyTo(dest) }
            }
            // already in the list: it comes in as a copy (iOS does the same)
            if (store.project(p.id) != null) p = p.copy(id = UUID.randomUUID())
            p = p.copy(modified = AppleDate.now())
            store.save(p)
            Result.Opened(p, p.mediaFiles.count { !Paths.mediaFile(it).exists() })
        } finally {
            temp.deleteRecursively()
        }
    }
}
