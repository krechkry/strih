// Stand-in for Bombocut/Editor/Preview.swift: the project playing through Media3's CompositionPlayer.
@file:OptIn(androidx.media3.common.util.UnstableApi::class, androidx.media3.common.util.ExperimentalApi::class)
package cz.krechler.bombocut.editor

import android.view.SurfaceView
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import androidx.media3.common.Player
import androidx.media3.transformer.CompositionPlayer
import cz.krechler.bombocut.engine.CompositionBuilder
import cz.krechler.bombocut.model.Project
import kotlinx.coroutines.delay

/** Holds the player for one open project; the editor reads `time` / `playing` and calls play, pause, seek. */
class PreviewState {
    var player: CompositionPlayer? = null
    var time by mutableStateOf(0.0)
    var playing by mutableStateOf(false)
    var error by mutableStateOf<String?>(null)

    fun toggle() { val p = player ?: return; if (p.isPlaying) p.pause() else { if (p.playbackState == Player.STATE_ENDED) p.seekTo(0); p.play() } }
    fun seek(t: Double) { player?.seekTo((t * 1000).toLong()); time = t }
}

@Composable
fun PreviewView(project: Project, state: PreviewState, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val surface = remember { SurfaceView(context) }
    val (w, h) = project.canvas.size(720)

    DisposableEffect(Unit) {
        val p = CompositionPlayer.Builder(context).build()
        p.addListener(object : Player.Listener {
            override fun onIsPlayingChanged(isPlaying: Boolean) { state.playing = isPlaying }
            override fun onPlayerError(error: androidx.media3.common.PlaybackException) { state.error = error.message }
        })
        p.setVideoSurfaceView(surface)
        state.player = p
        onDispose { state.player = null; p.release() }
    }
    // rebuilt when the timing or the shape changes (like iOS `rebuild()`)
    LaunchedEffect(project.clips, project.canvas) {
        val p = state.player ?: return@LaunchedEffect
        val comp = CompositionBuilder.build(project, w, h) ?: return@LaunchedEffect
        p.setComposition(comp, (state.time * 1000).toLong())
        p.prepare()
    }
    LaunchedEffect(Unit) {
        while (true) {
            state.player?.let { if (it.isPlaying) state.time = it.currentPosition / 1000.0 }
            delay(33)
        }
    }
    Box(modifier.background(Color.Black), contentAlignment = Alignment.Center) {
        AndroidView({ surface }, Modifier.aspectRatio(w.toFloat() / h).fillMaxSize())
    }
}
