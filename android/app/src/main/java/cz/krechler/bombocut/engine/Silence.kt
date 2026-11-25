// Ported from Bombocut/Engine/Silence.swift (iOS ad3827a): Remove silence. The pure parts (auto threshold, quiet
// stretches, what gets cut, the clip in pieces) are 1:1 and checked against the iPhone (SilenceParityTest,
// shared/parity/silence.json). The loudness comes from MediaCodec instead of AVAssetReader (same 10 ms RMS in
// dBFS; not resampled to 16 kHz first, which doesn't change an RMS level). Not yet: the cleaned-up speech
// (Remove noise) as the source.
package cz.krechler.bombocut.engine

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import cz.krechler.bombocut.editor.EditorModel
import cz.krechler.bombocut.model.Clip
import cz.krechler.bombocut.model.MotionAnim
import cz.krechler.bombocut.model.Paths
import kotlinx.serialization.Serializable
import java.nio.ByteOrder
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

object Silence {
    /** Loudness steps per second. */
    const val rate = 100.0

    @Serializable
    data class Settings(
        /** Quieter than this (dBFS) is silence; null: worked out from the clip. */
        val threshold: Double? = null,
        val minSilence: Double = 0.5,
        val before: Double = 0.1,
        val after: Double = 0.15,
        val fade: Double = 0.03,
    )

    /** 30 % of the way from the noise floor (quietest tenth) to the voice (loudest tenth), within -60...-20 dB. */
    fun autoThreshold(levels: List<Float>): Double {
        if (levels.size <= 10) return -40.0
        val s = levels.sorted()
        val floor = s[s.size / 10].toDouble(); val loud = s[s.size * 9 / 10].toDouble()
        return min(max(floor + 0.3 * (loud - floor), -60.0), -20.0)
    }

    /** Stretches quieter than `threshold` for at least `minSilence` (a blip under 60 ms inside a pause doesn't count). */
    fun quiet(levels: List<Float>, threshold: Double, minSilence: Double): List<ClosedFloatingPointRange<Double>> {
        val n = levels.size
        if (n == 0) return emptyList()
        val silent = BooleanArray(n) { levels[it].toDouble() < threshold }
        val blip = (0.06 * rate).toInt()
        var i = 0
        while (i < n) {
            if (silent[i]) { i++; continue }
            var j = i
            while (j < n && !silent[j]) j++
            if (j - i <= blip && i > 0 && j < n) for (k in i until j) silent[k] = true
            i = j
        }
        val out = mutableListOf<ClosedFloatingPointRange<Double>>()
        i = 0
        while (i < n) {
            if (!silent[i]) { i++; continue }
            var j = i
            while (j < n && silent[j]) j++
            val a = i / rate; val b = j / rate
            if (b - a >= minSilence - 1e-9) out.add(a..b)
            i = j
        }
        return out
    }

    /** What gets cut: each pause minus what's kept around the speech; a pause at the very start or end goes whole. */
    fun cuts(quiet: List<ClosedFloatingPointRange<Double>>, length: Double, s: Settings): List<ClosedFloatingPointRange<Double>> =
        quiet.mapNotNull { q ->
            val a = if (q.start < 0.011) 0.0 else q.start + s.after
            val b = if (q.endInclusive > length - 0.011) length else q.endInclusive - s.before
            if (b - a >= 0.05) a..min(b, length) else null
        }

    /** The clip in the pieces that stay (cuts in seconds from its in point); null when nothing changes or stays. */
    fun pieces(c: Clip, cuts: List<ClosedFloatingPointRange<Double>>, fade: Double): List<Clip>? {
        val len = c.outPoint - c.inPoint
        val keep = mutableListOf<ClosedFloatingPointRange<Double>>()
        var at = 0.0
        for (q in cuts.sortedBy { it.start }) {
            if (q.start - at >= 0.05) keep.add(at..q.start)
            at = max(at, q.endInclusive)
        }
        if (len - at >= 0.05) keep.add(at..len)
        if (keep.isEmpty() || (keep.size == 1 && keep[0].start < 0.001 && keep[0].endInclusive > len - 0.001)) return null

        val bounds = keep.flatMap { listOf(it.start, it.endInclusive) }.filter { it > 0.0005 && it < len - 0.0005 }
        val all = mutableListOf<Clip>()
        var rest = c
        for (b in bounds.sorted()) {
            EditorModel.clipHalves(rest, c.inPoint + b)?.let { (a, r) -> all.add(a); rest = r }
        }
        all.add(rest)
        fun kept(p: Clip): Boolean {
            val mid = (p.inPoint + p.outPoint) / 2 - c.inPoint
            return keep.any { mid in it }
        }
        val out = all.filter(::kept).toMutableList()
        if (out.isEmpty()) return null
        if (out[0].id != c.id) out[0] = out[0].copy(id = c.id, cut = c.cut, anim = out[0].anim.copy(inAnim = c.anim.inAnim))
        val last = out.size - 1
        out[last] = out[last].copy(anim = out[last].anim.copy(
            outAnim = if (out[last].outPoint < c.outPoint - 0.001) MotionAnim.none else c.anim.outAnim))
        val f = max(0.0, fade)
        for (k in out.indices) {
            val fi = if (k == 0 && out[k].inPoint <= c.inPoint + 0.001) c.fadeIn else if (k == 0) max(c.fadeIn, f) else f
            val fo = if (k == last && out[k].outPoint >= c.outPoint - 0.001) c.fadeOut else if (k == last) max(c.fadeOut, f) else f
            out[k] = out[k].copy(fadeIn = fi, fadeOut = fo)
        }
        return out
    }

    /** Loudness of the clip's sound over its source range (dBFS, `rate` steps a second), null without sound. */
    fun levels(c: Clip): List<Float>? {
        val ex = MediaExtractor()
        try {
            ex.setDataSource(Paths.mediaFile(c.mediaFile).path)
            val track = (0 until ex.trackCount).firstOrNull {
                ex.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
            } ?: return null
            ex.selectTrack(track)
            val fmt = ex.getTrackFormat(track)
            val codec = MediaCodec.createDecoderByType(fmt.getString(MediaFormat.KEY_MIME)!!)
            codec.configure(fmt, null, null, 0)
            codec.start()
            ex.seekTo((c.inPoint * 1e6).toLong(), MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            val endUs = (c.outPoint * 1e6).toLong()
            var sr = fmt.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            var ch = fmt.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            val out = ArrayList<Float>()
            var sum = 0.0; var count = 0
            val info = MediaCodec.BufferInfo()
            var inputDone = false; var outputDone = false
            while (!outputDone) {
                if (!inputDone) {
                    val i = codec.dequeueInputBuffer(10_000)
                    if (i >= 0) {
                        val n = ex.readSampleData(codec.getInputBuffer(i)!!, 0)
                        if (n < 0 || ex.sampleTime > endUs) {
                            codec.queueInputBuffer(i, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM); inputDone = true
                        } else { codec.queueInputBuffer(i, 0, n, ex.sampleTime, 0); ex.advance() }
                    }
                }
                val o = codec.dequeueOutputBuffer(info, 10_000)
                if (o == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    codec.outputFormat.let { sr = it.getInteger(MediaFormat.KEY_SAMPLE_RATE); ch = it.getInteger(MediaFormat.KEY_CHANNEL_COUNT) }
                } else if (o >= 0) {
                    val per = max(1, (sr / rate).roundToInt())
                    val buf = codec.getOutputBuffer(o)!!.order(ByteOrder.nativeOrder()).asShortBuffer()
                    val frames = info.size / 2 / ch
                    // only the part from the in point on
                    val skip = if (info.presentationTimeUs < (c.inPoint * 1e6).toLong())
                        min(frames, (((c.inPoint * 1e6).toLong() - info.presentationTimeUs) * sr / 1_000_000).toInt()) else 0
                    for (f in skip until frames) {
                        var m = 0.0
                        for (k in 0 until ch) m += buf.get(f * ch + k) / 32768.0
                        m /= ch
                        sum += m * m; count++
                        if (count == per) { out.add((10 * log10(sum / per + 1e-12)).toFloat()); sum = 0.0; count = 0 }
                    }
                    codec.releaseOutputBuffer(o, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) outputDone = true
                }
            }
            codec.stop(); codec.release()
            val want = ((c.outPoint - c.inPoint) * rate).roundToInt()
            while (out.size < want) out.add(out.lastOrNull() ?: -100f)
            return out.take(want)
        } catch (e: Exception) {
            return null
        } finally {
            ex.release()
        }
    }
}
