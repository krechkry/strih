// Ported from Bombocut/Engine/CompositionBuilder.swift (iOS ad3827a), on Media3 instead of AVFoundation.
// iOS inserts one time-scaled piece per Retime segment; Media3 takes the same pieces as a SpeedProvider.
// Covered so far: clips in order, trims, constant speed and speed curves (pitch kept or not), clip volume and
// sound fades, fit / fill on the canvas, the look (LookLut), text layers and captions (TextLayer). Not yet:
// video layers, transition shapes other than a crossfade, Speech / Reverse on sounds. Sound items: SoundSequences.
@file:OptIn(androidx.media3.common.util.UnstableApi::class, androidx.media3.common.util.ExperimentalApi::class)
package cz.krechler.bombocut.engine

import android.net.Uri
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.OverlaySettings
import androidx.media3.common.VideoCompositorSettings
import androidx.media3.common.util.Size
import androidx.media3.effect.StaticOverlaySettings
import androidx.media3.common.SpeedParameters
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.GainProcessor
import androidx.media3.common.audio.SpeedProvider
import androidx.media3.effect.Presentation
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.Effects
import cz.krechler.bombocut.model.AudioItem
import cz.krechler.bombocut.model.Clip
import cz.krechler.bombocut.model.Fade
import cz.krechler.bombocut.model.Paths
import cz.krechler.bombocut.model.Project
import cz.krechler.bombocut.model.Retime
import kotlin.math.abs
import kotlin.math.roundToLong

object CompositionBuilder {
    fun us(seconds: Double): Long = (seconds * 1_000_000).roundToLong()

    /**
     * The clip's Retime as a Media3 SpeedProvider. Media3 asks with media time measured from the clip's in point
     * (SpeedChangingMediaSource subtracts the clipping start), which is exactly `src0 - inPoint` of our pieces.
     * Returns null at plain 1x (no speed stage at all, like iOS inserting without scaling).
     */
    fun speedProvider(rt: Retime, inPoint: Double): SpeedProvider? {
        if (rt.segs.size == 1 && abs(rt.speed(0.0) - 1) < 1e-6) return null
        val starts = rt.segs.map { us(it.src0 - inPoint) }
        val speeds = rt.segs.map { (it.srcLen / maxOf(it.outLen, 1e-12)).toFloat() }
        return object : SpeedProvider {
            private fun index(timeUs: Long): Int {
                var lo = 0; var hi = starts.size - 1
                while (lo < hi) { val mid = (lo + hi + 1) / 2; if (starts[mid] <= timeUs) lo = mid else hi = mid - 1 }
                return lo
            }
            override fun getSpeed(timeUs: Long): Float = speeds[index(maxOf(0, timeUs))]
            override fun getNextSpeedChangeTimeUs(timeUs: Long): Long {
                val i = index(maxOf(0, timeUs))
                return if (i + 1 < starts.size) starts[i + 1] else C.TIME_UNSET
            }
        }
    }

    /** Volume and the sound fades (Swift: volume ramps on the audio mix), on timeline time after the speed change. */
    fun gain(volume: Double, fades: Pair<Double, Double>, length: Double): AudioProcessor? {
        if (abs(volume - 1) < 1e-4 && fades.first < 0.01 && fades.second < 0.01) return null
        return GainProcessor(object : GainProcessor.GainProvider {
            override fun getGainFactorAtSamplePosition(samplePosition: Long, sampleRate: Int): Float {
                val t = samplePosition.toDouble() / sampleRate
                return (volume * Fade.gain(t, length, fades)).toFloat().coerceIn(0f, 1f)
            }
            override fun isUnityUntil(samplePosition: Long, sampleRate: Int): Long = C.TIME_UNSET.let {
                // never unity unless the volume is 1 and we are between the fades
                if (abs(volume - 1) > 1e-4) samplePosition else {
                    val t = samplePosition.toDouble() / sampleRate
                    if (t >= fades.first && t < length - fades.second) ((length - fades.second) * sampleRate).toLong() else samplePosition
                }
            }
        })
    }

    /**
     * One clip. `head` / `tail`: output seconds left off its start / end. Until transitions blend on Android, a
     * transition is a cut in its middle: each clip gives up half the overlap, so every clip, text, caption and
     * sound still sits where the timeline (and the iPhone) has it.
     */
    fun item(c: Clip, width: Int, height: Int, head: Double = 0.0, tail: Double = 0.0): EditedMediaItem {
        val rt = c.retime
        val h = head.coerceIn(0.0, maxOf(0.0, rt.outDuration - 0.05))
        val t = tail.coerceIn(0.0, maxOf(0.0, rt.outDuration - h - 0.05))
        val start = if (h > 0) rt.source(h) else c.inPoint
        val end = if (t > 0) rt.source(rt.outDuration - t) else c.outPoint
        val length = rt.outDuration - h - t
        android.util.Log.i("Bombocut", "clip ${c.id}: source ${start}..${end}, plays ${length} s (head $h, tail $t)")
        val media = MediaItem.Builder()
            .setUri(Uri.fromFile(Paths.mediaFile(c.mediaFile)))
            .setClippingConfiguration(
                MediaItem.ClippingConfiguration.Builder()
                    .setStartPositionUs(us(start))
                    .setEndPositionUs(us(end))
                    .build()
            )
            .build()
        val audio = listOfNotNull(gain(c.volume, c.fades, length))
        val layout = if (c.fill) Presentation.LAYOUT_SCALE_TO_FIT_WITH_CROP else Presentation.LAYOUT_SCALE_TO_FIT
        // the look first (on the clip's own picture, like iOS), then placed on the canvas
        val video = listOfNotNull(LookLut.effect(c.look(c.inPoint).effects), Presentation.createForWidthAndHeight(width, height, layout))
        // CompositionPlayer needs the whole file's length up front (Swift: the asset's time range)
        val b = EditedMediaItem.Builder(media).setEffects(Effects(audio, video)).setDurationUs(us(c.sourceDuration))
        speedProvider(rt, start)?.let { b.setSpeed(SpeedParameters(it, c.pitchCorrect)) }
        return b.build()
    }

    /** A constant speed as a provider (sounds have one speed, no curves). */
    private fun constantSpeed(speed: Float) = object : SpeedProvider {
        override fun getSpeed(timeUs: Long): Float = speed
        override fun getNextSpeedChangeTimeUs(timeUs: Long): Long = C.TIME_UNSET
    }

    /** One sound item (music, a voice-over, sound from a video), its own volume and fades, pitch kept. */
    fun soundItem(a: AudioItem, length: Double): EditedMediaItem {
        val media = MediaItem.Builder()
            .setUri(Uri.fromFile(Paths.mediaFile(a.file)))
            .setClippingConfiguration(
                MediaItem.ClippingConfiguration.Builder()
                    .setStartPositionUs(us(a.inPoint))
                    .setEndPositionUs(us(minOf(a.sourceDuration, a.inPoint + length * a.speed)))
                    .build()
            )
            .build()
        val audio = listOfNotNull(gain(a.volume, a.fades, length))
        val b = EditedMediaItem.Builder(media).setRemoveVideo(true).setEffects(Effects(audio, emptyList()))
            .setDurationUs(us(a.sourceDuration))
        if (abs(a.speed - 1) > 1e-4) b.setSpeed(SpeedParameters(constantSpeed(a.speed.toFloat()), true))
        return b.build()
    }

    /**
     * The sounds as audio-only sequences: overlapping sounds go on separate rows (Media3 plays a sequence one item
     * after another), gaps fill the time between them. Nothing plays past the end of the video.
     */
    fun soundSequences(project: Project): List<EditedMediaItemSequence> {
        val total = project.duration
        val rows = mutableListOf<MutableList<AudioItem>>()
        for (a in project.audio.filter { it.start < total - 0.01 && it.duration > 0.01 }.sortedBy { it.start }) {
            val row = rows.firstOrNull { it.last().end <= a.start + 1e-6 }
            if (row != null) row.add(a) else rows.add(mutableListOf(a))
        }
        return rows.map { row ->
            val b = EditedMediaItemSequence.Builder(setOf(C.TRACK_TYPE_AUDIO))
            var t = 0.0
            for (a in row) {
                if (a.start - t > 0.001) b.addGap(us(a.start - t))
                val length = minOf(a.duration, total - a.start)
                b.addItem(soundItem(a, length))
                t = a.start + length
            }
            b.build()
        }
    }

    /** Even clips on roll A, odd clips on roll B, each at its own timeline start; A runs to the very end. */
    private fun abRolls(project: Project, width: Int, height: Int): List<EditedMediaItemSequence> {
        val starts = project.clipStarts
        val total = project.duration
        return (0..1).map { roll ->
            val b = EditedMediaItemSequence.Builder(setOf(C.TRACK_TYPE_AUDIO, C.TRACK_TYPE_VIDEO))
            var t = 0.0
            for (k in project.clips.indices) {
                if (k % 2 != roll) continue
                val c = project.clips[k]
                if (starts[k] - t > 0.001) b.addGap(us(starts[k] - t))
                b.addItem(item(c, width, height))
                t = starts[k] + c.duration
            }
            // the primary roll sets the output's length: it covers the whole video
            if (roll == 0 && total - t > 0.001) b.addGap(us(total - t))
            b.build()
        }
    }

    /**
     * How each roll shows at each moment (see `alpha`). All transitions blend as a crossfade on Android for now
     * (iOS also slides, zooms and pops).
     */
    private class Crossfades(project: Project, private val w: Int, private val h: Int) : VideoCompositorSettings {
        private val starts = project.clipStarts
        private val ends = project.clips.mapIndexed { k, c -> starts[k] + c.duration }
        private val n = project.clips.size

        /**
         * How much of roll `roll` shows at t: none while it is in a gap (its gap frames are black), all of it while
         * its clip plays alone, and the incoming clip fades in over the outgoing one across an overlap.
         */
        fun alpha(roll: Int, t: Double): Float {
            for (k in 0 until n) {
                if (t < starts[k] - 1e-6 || t >= ends[k]) continue
                val nextStarts = if (k + 1 < n) starts[k + 1] else Double.MAX_VALUE
                if (t >= nextStarts) {
                    // overlap of k (out) and k + 1 (in)
                    val f = ((t - nextStarts) / maxOf(ends[k] - nextStarts, 1e-6)).coerceIn(0.0, 1.0)
                    return if ((k + 1) % 2 == roll) f.toFloat() else 1f
                }
                return if (k % 2 == roll) 1f else 0f
            }
            return 0f
        }

        override fun getOutputSize(inputSizes: List<Size>): Size = Size(w, h)

        private var logged = 0

        override fun getOverlaySettings(inputId: Int, presentationTimeUs: Long): OverlaySettings {
            val a = alpha(inputId, presentationTimeUs / 1_000_000.0)
            if (a > 0.01f && a < 0.99f && logged < 12) { logged++; android.util.Log.i("Bombocut", "blend input $inputId at $presentationTimeUs us: alpha $a") }
            return StaticOverlaySettings.Builder().setAlphaScale(a).build()
        }
    }

    /** The project as one Media3 Composition, `width` x `height` (preview and export use the same one). */
    fun build(project: Project, width: Int, height: Int, fps: Double? = null, livePreview: Boolean = false): Composition? {
        if (project.clips.isEmpty()) return null
        val n = project.clips.size
        val blends = (1 until n).any { project.overlap(it) > 0.01 }
        val video: List<EditedMediaItemSequence>
        var settings: VideoCompositorSettings? = null
        if (blends) {
            // transitions: A / B rolls like an editor's two tracks. Even clips on A (drawn on top), odd ones on B,
            // each at its timeline start with gaps between; over an overlap A fades out (or in) over B.
            video = abRolls(project, width, height)
            settings = Crossfades(project, width, height)
        } else {
            val items = project.clips.map { item(it, width, height) }
            video = listOf(EditedMediaItemSequence.Builder(items).build())
        }
        val b = Composition.Builder(video + soundSequences(project))
        settings?.let { b.setVideoCompositorSettings(it) }
        // over the whole picture: texts and captions; export: the frame rate asked for (the preview plays the footage's own)
        val whole = listOfNotNull(
            TextLayer.effect(project, width, height, livePreview),
            fps?.let { androidx.media3.effect.FrameDropEffect.createDefaultFrameDropEffect(it.toFloat()) },
        )
        if (whole.isNotEmpty()) b.setEffects(Effects(emptyList(), whole))
        return b.build()
    }
}
