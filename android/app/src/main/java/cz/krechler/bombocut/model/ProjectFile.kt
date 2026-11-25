// Part port of Bombocut/Model/ProjectFile.swift (iOS ad3827a): opening a .bbc project file (a plain zip:
// bombocut.json, project.json, Media/, Fonts/, LUTs/). The project lands in the list (a copy when it is already
// there), its videos in the media folder. Not yet: writing .bbc files, fonts and LUTs (they stay out), light files'
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
