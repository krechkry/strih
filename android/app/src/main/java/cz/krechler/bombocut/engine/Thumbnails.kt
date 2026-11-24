// Stand-in for Bombocut/Engine/Thumbnails.swift: frames of a clip for Home and (later) the filmstrip.
// Media3's FrameExtractor will replace MediaMetadataRetriever once the editor's filmstrip needs speed.
package cz.krechler.bombocut.engine

import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.util.LruCache
import cz.krechler.bombocut.model.Paths
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

object ThumbnailCache {
    private val cache = LruCache<String, Bitmap>(120)

    /** A small frame of `file` at `seconds` (cached), null when it can't be read. */
    suspend fun image(file: String, seconds: Double, maxSide: Int = 240): Bitmap? {
        val key = "$file@${(seconds * 10).toInt()}@$maxSide"
        cache.get(key)?.let { return it }
        return withContext(Dispatchers.IO) {
            runCatching {
                val r = MediaMetadataRetriever()
                try {
                    r.setDataSource(Paths.mediaFile(file).path)
                    val us = (seconds * 1_000_000).toLong()
                    val bmp = r.getScaledFrameAtTime(us, MediaMetadataRetriever.OPTION_CLOSEST_SYNC, maxSide, maxSide)
                    bmp?.also { cache.put(key, it) }
                } finally { r.release() }
            }.getOrNull()
        }
    }
}
