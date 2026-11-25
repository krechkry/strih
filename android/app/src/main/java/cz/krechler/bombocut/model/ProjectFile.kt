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
        out.outputStream().buffered().use { pack(p, it) { name -> Paths.mediaFile(name) } }
        out
    }

    /** The zip itself, `media` finding each video by its name (testable without a phone). */
    fun pack(p: Project, to: java.io.OutputStream, media: (String) -> File) {
        val files = p.mediaFiles.filter { media(it).exists() }.sorted()
        val bytes = files.sumOf { media(it).length() }
        val manifest = Manifest(1, "BOMBOCUT Android", p.name, AppleDate.now(), files, emptyList(), emptyList(), bytes)
        java.util.zip.ZipOutputStream(to).use { zip ->
            zip.setLevel(java.util.zip.Deflater.DEFAULT_COMPRESSION)
            zip.putNextEntry(java.util.zip.ZipEntry("bombocut.json"))
            zip.write(Json.encodeToString(Manifest.serializer(), manifest).encodeToByteArray())
            zip.closeEntry()
            zip.putNextEntry(java.util.zip.ZipEntry("project.json"))
            zip.write(BomboJson.encodeToString(Project.serializer(), p).encodeToByteArray())
            zip.closeEntry()
            zip.setLevel(java.util.zip.Deflater.NO_COMPRESSION)
            for (m in files) {
                zip.putNextEntry(java.util.zip.ZipEntry("Media/$m"))
                media(m).inputStream().use { it.copyTo(zip) }
                zip.closeEntry()
            }
        }
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

    sealed class Unpacked {
        data class Ok(val project: Project) : Unpacked()
        data object NotAProject : Unpacked()
        data object NewerFormat : Unpacked()
    }

    /**
     * Reads a .bbc: the project, and each video it uses that `dest` says isn't there yet is copied to it (`temp`
     * holds the videos until the project is known: the zip may list them before project.json).
     */
    fun unpack(input: java.io.InputStream, temp: File, dest: (String) -> File): Unpacked {
        temp.mkdirs()
        var manifest: String? = null
        var body: String? = null
        ZipInputStream(input.buffered()).use { zip ->
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
        val head = manifest ?: return Unpacked.NotAProject
        val f = runCatching { Json.parseToJsonElement(head).jsonObject["format"]?.jsonPrimitive?.intOrNull }.getOrNull()
            ?: return Unpacked.NotAProject
        if (f > format) return Unpacked.NewerFormat
        val p = runCatching { BomboJson.decodeFromString(Project.serializer(), body ?: "") }.getOrNull()
            ?: return Unpacked.NotAProject
        for (name in p.mediaFiles) {
            val src = File(temp, name)
            val to = dest(name)
            if (src.exists() && !to.exists()) { if (!src.renameTo(to)) src.copyTo(to) }
        }
        return Unpacked.Ok(p)
    }

    suspend fun open(context: Context, uri: Uri, store: ProjectStore): Result = withContext(Dispatchers.IO) {
        Paths.ensure()
        val temp = File(context.cacheDir, "Unpack-" + UUID.randomUUID())
        try {
            val r = context.contentResolver.openInputStream(uri)?.use { unpack(it, temp) { n -> Paths.mediaFile(n) } }
                ?: return@withContext Result.NotAProject
            var p = when (r) {
                is Unpacked.Ok -> r.project
                Unpacked.NotAProject -> return@withContext Result.NotAProject
                Unpacked.NewerFormat -> return@withContext Result.NewerFormat
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
