// Ported from Bombocut/Engine/CompositionBuilder.swift (iOS ad3827a), on Media3 instead of AVFoundation.
// iOS inserts one time-scaled piece per Retime segment; Media3 takes the same pieces as a SpeedProvider.
// Covered so far: clips in order, trims, constant speed and speed curves (pitch kept or not), clip volume and
// sound fades, fit / fill on the canvas, the look (LookLut), text layers and captions (TextLayer), transitions
// (A / B rolls with every iOS shape: fade, slides, zooms, pop), video layers as their own compositor inputs
// (placement, keyframes, animations, speed, volume). Not yet: video layers' look / crop / mask / blend mode, motion blur in
// transitions, Speech / Reverse on sounds. Sound items: soundSequences.
@file:OptIn(androidx.media3.common.util.UnstableApi::class, androidx.media3.common.util.ExperimentalApi::class)
package cz.krechler.bombocut.engine

import android.net.Uri
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.OverlaySettings
import androidx.media3.common.VideoCompositorSettings
import androidx.media3.common.util.Size
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
import cz.krechler.bombocut.model.MotionAnim
import cz.krechler.bombocut.model.Overlay
import cz.krechler.bombocut.model.OverlayKind
import cz.krechler.bombocut.model.Paths
import cz.krechler.bombocut.model.Project
import cz.krechler.bombocut.model.Retime
import kotlin.math.abs
import kotlin.math.roundToInt
import kotlin.math.roundToLong

object CompositionBuilder {
    /** Real transition blends (two rolls and the compositor); see build(). */
    private const val BLENDS = true

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
        return GainProcessor(gainProvider(volume, fades, length))
    }

    fun gainProvider(volume: Double, fades: Pair<Double, Double>, length: Double): GainProcessor.GainProvider {
        return (object : GainProcessor.GainProvider {
            override fun getGainFactorAtSamplePosition(samplePosition: Long, sampleRate: Int): Float {
                val t = samplePosition.toDouble() / sampleRate
                return (volume * Fade.gain(t, length, fades)).toFloat().coerceIn(0f, 1f)
            }
            /**
             * GainProcessor asks only where the gain is exactly 1 and copies up to the answer: answering the same
             * position there made it loop forever (the first sample of a fade-out, or a volume over 100 % clamped
             * to 1), freezing the preview and the export. A unity sample always moves on by at least one.
             */
            override fun isUnityUntil(samplePosition: Long, sampleRate: Int): Long {
                if (getGainFactorAtSamplePosition(samplePosition, sampleRate) != 1f) return samplePosition
                if (fades.second < 0.01) return C.TIME_END_OF_SOURCE
                return maxOf(samplePosition + 1, ((length - fades.second) * sampleRate).toLong())
            }
        })
    }

    /**
     * One clip. `head` / `tail`: output seconds left off its start / end. Until transitions blend on Android, a
     * transition is a cut in its middle: each clip gives up half the overlap, so every clip, text, caption and
     * sound still sits where the timeline (and the iPhone) has it.
     */
    fun item(c: Clip, width: Int, height: Int, head: Double = 0.0, tail: Double = 0.0, fades: Pair<Double, Double>? = null): EditedMediaItem {
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
        val audio = listOfNotNull(gain(c.volume, fades ?: c.fades, length))
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

    /**
     * Where a clip plays when transitions blend (Swift: `Placed` in CompositionBuilder.build): its roll, its
     * timeline start and the clip itself with the handles a transition uses (footage past its ends). `window`:
     * length of the transition it comes in with (0: none). `fades`: the sound's ramps, the transition's window
     * in place of the clip's own fade on a side that blends (iOS: volume ramps across the overlap).
     */
    data class Placed(val k: Int, val clip: Clip, val start: Double, val roll: Int, val window: Double, val fades: Pair<Double, Double>) {
        val end: Double get() = start + clip.duration
    }

    /**
     * The clips on two rolls like an editor's A and B tracks: a transition always moves to the other roll (iOS
     * `lane = 1 - lane`). Media3 draws roll A on top and can't change that per frame; only Pop needs the clip
     * coming in on top, so each chain of transitions starts on the roll that puts most Pops' incoming clip on A.
     */
    fun placeRolls(project: Project): List<Placed> {
        val n = project.clips.size
        val windows = (0 until n).map { k -> if (k == 0) 0.0 else project.cutShape(k).let { it.shrink + it.tail + it.head } }
        val blended = windows.map { it > 0.001 }
        val roll = IntArray(n)
        var k = 0
        while (k < n) {
            var e = k
            while (e + 1 < n && blended[e + 1]) e++
            fun pops(p: Int) = (k + 1..e).count { j -> project.clips[j].cut?.kind == MotionAnim.pop && (p + j - k) % 2 == 0 }
            val p = if (pops(1) > pops(0)) 1 else 0
            for (j in k..e) roll[j] = (p + j - k) % 2
            k = e + 1
        }
        val out = ArrayList<Placed>(n)
        for (j in 0 until n) {
            val c = project.clips[j]
            val head = if (blended[j]) project.cutShape(j).head else 0.0
            val tail = if (j + 1 < n && blended[j + 1]) project.cutShape(j + 1).tail else 0.0
            val clip = c.withHandles(head, tail)
            val before = out.lastOrNull()
            val start = when {
                before == null -> 0.0
                blended[j] -> maxOf(before.start, before.end - windows[j])
                else -> before.end
            }
            val fadeIn = if (blended[j]) windows[j] else c.fades.first
            val fadeOut = if (j + 1 < n && blended[j + 1]) windows[j + 1] else c.fades.second
            out.add(Placed(j, clip, start, roll[j], if (blended[j]) windows[j] else 0.0, fadeIn to fadeOut))
        }
        return out
    }

    /**
     * Each roll as one sequence: its clips at their timeline starts with gaps between, both rolls to the very end
     * (a roll ending early made the compositor fail when a last frame of it still came in). Transformer only
     * composites when every roll's first item has video, so the roll without the first clip opens with that clip
     * again (silent by volume, hidden by the compositor) up to where its own first clip starts.
     */
    private fun rolls(project: Project, placed: List<Placed>, width: Int, height: Int): List<Pair<Int, EditedMediaItemSequence>> {
        val total = placed.last().end
        return (0..1).filter { r -> placed.any { it.roll == r } }.map { r -> r to run {
            val b = EditedMediaItemSequence.Builder(setOf(C.TRACK_TYPE_AUDIO, C.TRACK_TYPE_VIDEO))
            var t = 0.0
            val first = placed.firstOrNull { it.roll == r }
            if (placed[0].roll != r && first != null) {
                val c0 = project.clips[0].copy(volume = 0.0)
                val len = minOf(c0.duration, first.start)
                b.addItem(item(c0, width, height, tail = c0.duration - len))
                t = len
            }
            for (q in placed) {
                if (q.roll != r) continue
                if (q.start - t > 0.001) b.addGap(us(q.start - t))
                b.addItem(item(q.clip, width, height, fades = q.fades))
                t = q.end
            }
            if (total - t > 0.001) b.addGap(us(total - t))
            b.build()
        } }
    }

    /** How one roll shows at one moment: opacity, offset (canvas fractions, + = right / down) and scale. */
    data class RollPose(val alpha: Double, val dx: Double = 0.0, val dy: Double = 0.0, val scale: Double = 1.0, val rotation: Double = 0.0)

    /**
     * Roll `roll` at timeline time t. In a transition: the iOS poses (CutTransition.poses) of the clip going out
     * and the one coming in. Roll A is always drawn over B, so when the incoming clip is on B its opacity is
     * moved onto the outgoing clip above it (A at 1 - e over B at 1 shows the same mix as B at e over A); slides
     * don't overlap, so they keep their own. Outside transitions: the clip's roll shows, the other is hidden.
     */
    fun rollPose(placed: List<Placed>, project: Project, roll: Int, t: Double): RollPose {
        for (q in placed) {
            if (q.window <= 0.001 || q.k == 0 || t < q.start - 1e-6 || t >= q.start + q.window) continue
            val cut = project.clips[q.k].cut ?: continue
            val (o, i) = cut.poses(t - q.start, q.window)
            val outRoll = placed[q.k - 1].roll
            val slide = cut.kind in setOf(MotionAnim.slideLeft, MotionAnim.slideRight, MotionAnim.slideUp, MotionAnim.slideDown)
            val incomingOnTop = q.roll == 0 || slide
            return when (roll) {
                q.roll -> RollPose(if (incomingOnTop) i.opacity else if (i.opacity > 0) 1.0 else 0.0, i.dx, i.dy, i.scale)
                outRoll -> RollPose(if (incomingOnTop) o.opacity else o.opacity * (1 - i.opacity), o.dx, o.dy, o.scale)
                else -> RollPose(0.0)
            }
        }
        val q = placed.lastOrNull { t >= it.start - 1e-6 } ?: placed.first()
        return RollPose(if (q.roll == roll) 1.0 else 0.0)
    }

    /** Video layers that play over the clips, top first (the last in the project's list is drawn on top, like TextLayer). */
    fun videoLayers(project: Project): List<Overlay> {
        val total = project.duration
        return project.overlays.filter { it.kind is OverlayKind.Video && it.start < total - 0.01 && it.duration > 0.01 }.asReversed()
    }

    /** A video layer's size on the canvas at scale 1, in pixels (its box already has the video's aspect). */
    private fun layerSize(o: Overlay, w: Int, h: Int): Pair<Int, Int> {
        val (bw, bh) = o.baseFraction(w.toDouble() / h)
        return maxOf(2, (bw * w).roundToInt() / 2 * 2) to maxOf(2, (bh * h).roundToInt() / 2 * 2)
    }

    private fun layerItem(file: String, sourceDuration: Double, from: Double, to: Double, lw: Int, lh: Int,
                          volume: Double, length: Double, speed: SpeedProvider?): EditedMediaItem {
        val media = MediaItem.Builder()
            .setUri(Uri.fromFile(Paths.mediaFile(file)))
            .setClippingConfiguration(MediaItem.ClippingConfiguration.Builder().setStartPositionUs(us(from)).setEndPositionUs(us(to)).build())
            .build()
        val audio = listOfNotNull(gain(volume, 0.0 to 0.0, length))
        val video = listOf(Presentation.createForWidthAndHeight(lw, lh, Presentation.LAYOUT_SCALE_TO_FIT_WITH_CROP))
        val b = EditedMediaItem.Builder(media).setEffects(Effects(audio, video)).setDurationUs(us(sourceDuration))
        speed?.let { b.setSpeed(SpeedParameters(it, true)) }
        return b.build()
    }

    /**
     * One video layer as its own compositor input: a hidden, silent opener from its own file (Transformer wants
     * every input to start with video), the layer at its time with its speed (or speed curve) and volume, then gaps
     * to the end. A layer starting in the first 40 ms starts that much earlier in its footage instead.
     */
    private fun layerSequence(o: Overlay, total: Double, width: Int, height: Int): EditedMediaItemSequence {
        val v = o.kind as OverlayKind.Video
        val (lw, lh) = layerSize(o, width, height)
        val b = EditedMediaItemSequence.Builder(setOf(C.TRACK_TYPE_AUDIO, C.TRACK_TYPE_VIDEO))
        val length = minOf(o.duration, total - o.start)
        var t = 0.0
        var lead = 0.0
        if (o.start >= 0.04) {
            val len = minOf(o.start, v.sourceDuration)
            b.addItem(layerItem(v.file, v.sourceDuration, 0.0, len, lw, lh, 0.0, len, null))
            t = len
            if (o.start - t > 0.001) b.addGap(us(o.start - t))
            t = o.start
        } else lead = o.start
        val rt = o.curveRetime
        if (rt != null) {
            val from = v.inPoint
            val to = rt.source(rt.local(v.inPoint) + length)
            b.addItem(layerItem(v.file, v.sourceDuration, from, to, lw, lh, o.volume, length, speedProvider(rt, from)))
        } else {
            val from = maxOf(0.0, v.inPoint - lead * o.speed)
            val to = minOf(v.sourceDuration, v.inPoint + length * o.speed)
            val sp = if (abs(o.speed - 1) > 1e-4) constantSpeed(o.speed.toFloat()) else null
            b.addItem(layerItem(v.file, v.sourceDuration, from, to, lw, lh, o.volume, length + lead, sp))
        }
        t += length + lead
        if (total - t > 0.001) b.addGap(us(total - t))
        return b.build()
    }

    /** Where a video layer is at timeline time t (TextLayer's placement): offset from the center, scale, turn. */
    fun layerPose(o: Overlay, t: Double): RollPose {
        if (t < o.start - 1e-4 || t >= o.end) return RollPose(0.0)
        val (tr, opacity) = o.pose(t)
        val a = o.anim.pose(t - o.start, o.duration)
        return RollPose(opacity * a.opacity, tr.x + a.dx, tr.y + a.dy, tr.scale * a.scale, tr.rotation)
    }

    /**
     * The compositor's side: inputs are the video layers (top first), then the clip rolls. Media3 draws its inputs
     * top to bottom in that order. Each input's pose as overlay settings, implemented directly because the
     * builder only takes anchors inside the frame and a slide moves a whole frame.
     */
    private class Layout(private val project: Project, private val placed: List<Placed>, private val layers: List<Overlay>,
                         private val rollOf: List<Int>, private val w: Int, private val h: Int) : VideoCompositorSettings {
        override fun getOutputSize(inputSizes: List<Size>): Size = Size(w, h)

        private var logged = 0

        override fun getOverlaySettings(inputId: Int, presentationTimeUs: Long): OverlaySettings {
            val t = presentationTimeUs / 1_000_000.0
            val p = if (inputId < layers.size) layerPose(layers[inputId], t)
                    else rollPose(placed, project, rollOf.getOrElse(inputId - layers.size) { 0 }, t)
            if (p.alpha > 0.01 && p.alpha < 0.99 && logged < 12) { logged++; android.util.Log.i("Bombocut", "blend input $inputId at $presentationTimeUs us: alpha ${p.alpha}") }
            if (inputId < layers.size && p.alpha > 0.01 && logged < 16) { logged++; android.util.Log.i("Bombocut", "layer input $inputId at $presentationTimeUs us: $p") }
            return object : OverlaySettings {
                override fun getAlphaScale(): Float = p.alpha.toFloat().coerceAtLeast(0f)
                override fun getBackgroundFrameAnchor(): android.util.Pair<Float, Float> =
                    android.util.Pair((2 * p.dx).toFloat(), (-2 * p.dy).toFloat())
                override fun getScale(): android.util.Pair<Float, Float> = android.util.Pair(p.scale.toFloat(), p.scale.toFloat())
                // ours turns clockwise in radians, Media3's counter-clockwise in degrees
                override fun getRotationDegrees(): Float = (-Math.toDegrees(p.rotation)).toFloat()
            }
        }
    }

    /**
     * Whether the project goes through the compositor (transitions blend, video layers play) or plays as one roll
     * (a transition as a cut in its middle).
     */
    fun blends(project: Project): Boolean = BLENDS && (
        (1 until project.clips.size).any { project.cutShape(it).let { s -> s.shrink + s.tail + s.head } > 0.01 } ||
        videoLayers(project).isNotEmpty())

    /** The project as one Media3 Composition, `width` x `height` (preview and export use the same one). */
    fun build(project: Project, width: Int, height: Int, fps: Double? = null, livePreview: Boolean = false): Composition? {
        if (project.clips.isEmpty()) return null
        val n = project.clips.size
        val video: List<EditedMediaItemSequence>
        var settings: VideoCompositorSettings? = null
        if (blends(project)) {
            // transitions: A / B rolls blended by the compositor (the preview needs MultipleInputVideoGraph)
            val placed = placeRolls(project)
            // video layers first (drawn on top), then the clip rolls (only those that hold clips)
            val layers = videoLayers(project)
            val rolls = rolls(project, placed, width, height)
            video = layers.map { layerSequence(it, placed.last().end, width, height) } + rolls.map { it.second }
            settings = Layout(project, placed, layers, rolls.map { it.first }, width, height)
        } else {
            // no transitions, or blending off: one roll, a transition plays as a cut in its middle
            val items = project.clips.mapIndexed { k, c ->
                item(c, width, height, head = project.overlap(k) / 2, tail = if (k + 1 < n) project.overlap(k + 1) / 2 else 0.0)
            }
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
