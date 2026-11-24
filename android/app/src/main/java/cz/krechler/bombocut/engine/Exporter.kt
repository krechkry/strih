// Ported in part from Bombocut/Engine/Exporter.swift (iOS ad3827a): the same Composition as the preview, encoded
// by Media3's Transformer, saved to the gallery (Movies/BOMBOCUT). Presets match iOS (Sheets.swift ExportPreset).
// Not yet: the end card, HDR, custom size, the green guy, export steps beyond the progress.
@file:OptIn(androidx.media3.common.util.UnstableApi::class)
package cz.krechler.bombocut.engine

import android.content.ContentValues
import android.content.Context
import android.os.Environment
import android.provider.MediaStore
import androidx.media3.common.MimeTypes
import androidx.media3.transformer.Composition
import androidx.media3.transformer.DefaultEncoderFactory
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import androidx.media3.transformer.VideoEncoderSettings
import cz.krechler.bombocut.model.Project
import kotlinx.coroutines.suspendCancellableCoroutine
import java.io.File
import kotlin.coroutines.resume

data class ExportPreset(val id: String, val title: String, val shortSide: Int, val fps: Double, val mbps: Double) {
    companion object {
        val all = listOf(
            ExportPreset("fhd30", "Full HD · 30 fps", 1080, 30.0, 16.0),
            ExportPreset("fhd60", "Full HD · 60 fps", 1080, 60.0, 24.0),
            ExportPreset("uhd30", "4K · 30 fps", 2160, 30.0, 45.0),
            ExportPreset("uhd60", "4K · 60 fps", 2160, 60.0, 68.0),
        )
    }
}

object Exporter {
    sealed class Result {
        data class Saved(val file: File, val durationMs: Long) : Result()
        data class Failed(val message: String) : Result()
    }

    /** Renders the project to an .mp4 in the cache. `progress` gets 0...1. Runs on the main thread (Transformer's). */
    suspend fun render(context: Context, project: Project, preset: ExportPreset, hevc: Boolean = false,
                       progress: (Double) -> Unit): Result {
        val (w, h) = project.canvas.size(preset.shortSide)
        val comp = CompositionBuilder.build(project, w, h, preset.fps) ?: return Result.Failed("Nothing to export")
        val out = File(context.cacheDir, "export-${System.currentTimeMillis()}.mp4")
        val encoders = DefaultEncoderFactory.Builder(context)
            .setRequestedVideoEncoderSettings(VideoEncoderSettings.Builder().setBitrate((preset.mbps * 1_000_000).toInt()).build())
            .build()
        val holder = ProgressHolder()
        return suspendCancellableCoroutine { cont ->
            lateinit var transformer: Transformer
            transformer = Transformer.Builder(context)
                .setVideoMimeType(if (hevc) MimeTypes.VIDEO_H265 else MimeTypes.VIDEO_H264)
                .setAudioMimeType(MimeTypes.AUDIO_AAC)
                .setEncoderFactory(encoders)
                .addListener(object : Transformer.Listener {
                    override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                        if (cont.isActive) cont.resume(Result.Saved(out, exportResult.durationMs))
                    }
                    override fun onError(composition: Composition, exportResult: ExportResult, exportException: ExportException) {
                        if (cont.isActive) cont.resume(Result.Failed(exportException.message ?: "Export failed"))
                    }
                })
                .build()
            transformer.start(comp, out.path)
            cont.invokeOnCancellation { transformer.cancel() }
            // progress, polled like iOS's timer
            val handler = android.os.Handler(android.os.Looper.getMainLooper())
            val poll = object : Runnable {
                override fun run() {
                    if (!cont.isActive) return
                    if (transformer.getProgress(holder) == Transformer.PROGRESS_STATE_AVAILABLE) progress(holder.progress / 100.0)
                    handler.postDelayed(this, 200)
                }
            }
            handler.post(poll)
        }
    }

    /** Copies a rendered video into the gallery (Movies/BOMBOCUT), then deletes the temporary file. */
    fun saveToGallery(context: Context, file: File, name: String): Boolean = runCatching {
        val values = ContentValues().apply {
            put(MediaStore.Video.Media.DISPLAY_NAME, "$name.mp4")
            put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
            put(MediaStore.Video.Media.RELATIVE_PATH, Environment.DIRECTORY_MOVIES + "/BOMBOCUT")
            put(MediaStore.Video.Media.IS_PENDING, 1)
        }
        val r = context.contentResolver
        val uri = r.insert(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, values)!!
        r.openOutputStream(uri)!!.use { out -> file.inputStream().use { it.copyTo(out) } }
        values.clear(); values.put(MediaStore.Video.Media.IS_PENDING, 0)
        r.update(uri, values, null, null)
        file.delete()
        true
    }.getOrDefault(false)
}
