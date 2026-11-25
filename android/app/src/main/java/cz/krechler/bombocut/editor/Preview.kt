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
import cz.krechler.bombocut.engine.LiveLayers
import cz.krechler.bombocut.engine.TextLayer
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
    /** The project's length: the player's clock is never shown past it. */
    var length = 0.0
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
            override fun onPlaybackStateChanged(playbackState: Int) {
                android.util.Log.i("Bombocut", "preview state $playbackState, player duration ${p.duration} ms, project ${state.length} s, at ${p.currentPosition} ms")
                if (playbackState == Player.STATE_ENDED) state.time = state.length
            }
            override fun onPlayerError(error: androidx.media3.common.PlaybackException) { state.error = error.message }
        })
        p.setVideoSurfaceView(surface)
        state.player = p
        onDispose { state.player = null; p.release() }
    }
    // rebuilt when the timing or the shape changes (like iOS `rebuild()`)
    // (texts and captions are read live by the text layer: changing them only redraws the frame)
    LaunchedEffect(project.clips, project.canvas, project.audio, TextLayer.hasAny(project)) {
        val p = state.player ?: return@LaunchedEffect
        LiveLayers.project = project
        val comp = CompositionBuilder.build(project, w, h, livePreview = true) ?: return@LaunchedEffect
        state.length = project.duration
        p.setComposition(comp, (state.time * 1000).toLong())
        p.prepare()
    }
    val shown = remember { arrayOf<Any?>(null) }
    LaunchedEffect(project.overlays, project.captionTracks) {
        LiveLayers.project = project
        val key = project.overlays to project.captionTracks
        // the first time is the editor opening: the rebuild above takes care of it
        if (shown[0] == null) { shown[0] = key; return@LaunchedEffect }
        shown[0] = key
        // paused: a seek doesn't draw the paused frame again, so the composition is set again once typing pauses
        val p = state.player ?: return@LaunchedEffect
        if (p.isPlaying) return@LaunchedEffect
        delay(250)
        val comp = CompositionBuilder.build(project, w, h, livePreview = true) ?: return@LaunchedEffect
        p.setComposition(comp, (state.time * 1000).toLong())
        p.prepare()
    }
    LaunchedEffect(Unit) {
        while (true) {
            state.player?.let { if (it.isPlaying) state.time = minOf(it.currentPosition / 1000.0, state.length) }
            delay(33)
        }
    }
    Box(modifier.background(Color.Black), contentAlignment = Alignment.Center) {
        AndroidView({ surface }, Modifier.aspectRatio(w.toFloat() / h).fillMaxSize())
    }
}
