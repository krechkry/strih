// Ported from Bombocut/Engine/Beats.swift (iOS ad3827a): beats of a song, on the device. Onsets (40 log bands,
// 30 Hz to 8 kHz, level rise per 11.6 ms step, low bands twice), tempo (autocorrelation 55 to 200 BPM, pulled
// toward 120), beats (Ellis 2007 dynamic programming). vDSP's FFT is a plain radix-2 FFT here: its scale factors
// (zrip x2, Hann NORM) only shift every band's dB level by a constant, which the level rise cancels.
// Checked against the iPhone by BeatParityTest (shared/parity/beats.json).
package cz.krechler.bombocut.engine

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.ln
import kotlin.math.log10
import kotlin.math.log2
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlin.math.sqrt

object BeatDetector {
    const val sampleRate = 22050.0
    const val fftSize = 1024
    const val hop = 256
    val frameRate: Double get() = sampleRate / hop
    private const val bands = 40
    private const val lowBands = 12

    /** Beat times (seconds into the samples), from mono samples at `sampleRate`. */
    fun beats(samples: FloatArray): List<Double> {
        val env = onsets(samples)
        if (env.size <= (frameRate * 2).toInt()) return emptyList()
        val period = beatPeriod(env) ?: return emptyList()
        return track(env, period).map { it.toDouble() * hop / sampleRate }
    }

    fun tempo(samples: FloatArray): Double? = beatPeriod(onsets(samples))?.let { 60 * frameRate / it }

    /** In-place radix-2 FFT. */
    private fun fft(re: DoubleArray, im: DoubleArray) {
        val n = re.size
        var j = 0
        for (i in 1 until n) {
            var bit = n shr 1
            while (j and bit != 0) { j = j xor bit; bit = bit shr 1 }
            j = j xor bit
            if (i < j) { var t = re[i]; re[i] = re[j]; re[j] = t; t = im[i]; im[i] = im[j]; im[j] = t }
        }
        var len = 2
        while (len <= n) {
            val ang = -2 * PI / len
            val wr = cos(ang); val wi = sin(ang)
            var i = 0
            while (i < n) {
                var cr = 1.0; var ci = 0.0
                for (k in 0 until len / 2) {
                    val ur = re[i + k]; val ui = im[i + k]
                    val vr = re[i + k + len / 2] * cr - im[i + k + len / 2] * ci
                    val vi = re[i + k + len / 2] * ci + im[i + k + len / 2] * cr
                    re[i + k] = ur + vr; im[i + k] = ui + vi
                    re[i + k + len / 2] = ur - vr; im[i + k + len / 2] = ui - vi
                    val nr = cr * wr - ci * wi; ci = cr * wi + ci * wr; cr = nr
                }
                i += len
            }
            len = len shl 1
        }
    }

    fun onsets(x: FloatArray): FloatArray {
        val n = fftSize; val half = n / 2
        if (x.size <= n) return FloatArray(0)
        val bandOf = IntArray(half) { -1 }
        val lo = 30.0; val hi = 8000.0
        for (k in 1 until half) {
            val f = k * sampleRate / n
            if (f < lo || f >= hi) continue
            bandOf[k] = min(bands - 1, (ln(f / lo) / ln(hi / lo) * bands).toInt())
        }
        val window = DoubleArray(n) { 0.5 * (1 - cos(2 * PI * it / n)) }
        val padded = FloatArray(half + x.size + half).also { System.arraycopy(x, 0, it, half, x.size) }
        val steps = 1 + (padded.size - n) / hop
        val full = FloatArray(steps); val low = FloatArray(steps)
        val re = DoubleArray(n); val im = DoubleArray(n)
        var level = FloatArray(bands); var prev = FloatArray(bands)
        for (s in 0 until steps) {
            for (i in 0 until n) { re[i] = padded[s * hop + i] * window[i]; im[i] = 0.0 }
            fft(re, im)
            level.fill(0f)
            for (k in 1 until half) if (bandOf[k] >= 0) level[bandOf[k]] += (re[k] * re[k] + im[k] * im[k]).toFloat()
            for (b in 0 until bands) level[b] = (10 * log10(level[b] + 1e-10)).toFloat()
            if (s > 0) {
                var sum = 0f; var lowSum = 0f
                for (b in 0 until bands) {
                    val d = max(0f, level[b] - prev[b])
                    sum += d
                    if (b < lowBands) lowSum += d
                }
                full[s] = sum; low[s] = lowSum
            }
            val t = level; level = prev; prev = t
        }
        val a = normalized(highPass(full)); val b = normalized(highPass(low))
        return FloatArray(a.size) { a[it] + b[it] }
    }

    private fun highPass(v: FloatArray): FloatArray {
        val k = (0.4 * frameRate).roundToInt() or 1; val r = k / 2
        if (v.size <= k) return v
        val prefix = FloatArray(v.size + 1)
        for (i in v.indices) prefix[i + 1] = prefix[i] + v[i]
        return FloatArray(v.size) { i ->
            val a = max(0, i - r); val b = min(v.size, i + r + 1)
            max(0f, v[i] - (prefix[b] - prefix[a]) / k)
        }
    }

    /** vDSP_normalize: divided by the standard deviation (population), not centered. */
    private fun normalized(v: FloatArray): FloatArray {
        if (v.isEmpty()) return v
        val mean = v.sum() / v.size
        var sq = 0.0
        for (x in v) sq += ((x - mean) * (x - mean)).toDouble()
        val sd = sqrt(sq / v.size).toFloat()
        val s = if (sd > 1e-9f) sd else 1f
        return FloatArray(v.size) { v[it] / s }
    }

    fun beatPeriod(env: FloatArray): Double? {
        if (env.size <= 8) return null
        val mean = env.sum() / env.size
        val e = FloatArray(env.size) { env[it] - mean }
        val lo = (frameRate * 60 / 200).toInt(); val hi = (frameRate * 60 / 55).toInt()
        if (e.size <= hi + 2) return null
        fun ac(lag: Int): Double { var s = 0f; for (i in 0 until e.size - lag) s += e[i] * e[i + lag]; return s.toDouble() }
        val values = DoubleArray(hi + 2)
        for (lag in (lo - 1)..(hi + 1)) values[lag] = ac(lag)
        var bestScore = Double.NEGATIVE_INFINITY; var bestLag = -1
        for (lag in lo..hi) {
            val bpm = 60 * frameRate / lag
            val prior = exp(-0.5 * log2(bpm / 120).pow(2))
            val s = values[lag] * prior
            if (s > bestScore) { bestScore = s; bestLag = lag }
        }
        if (bestLag < 0 || bestScore <= 0) return null
        val y0 = values[bestLag - 1]; val y1 = values[bestLag]; val y2 = values[bestLag + 1]
        val den = y0 - 2 * y1 + y2
        val shift = if (abs(den) > 1e-12) min(max(0.5 * (y0 - y2) / den, -0.5), 0.5) else 0.0
        return bestLag + shift
    }

    fun track(env: FloatArray, period: Double, tightness: Double = 100.0): List<Int> {
        val n = env.size
        if (n <= 2 || period <= 1) return emptyList()
        val w = period.toInt()
        val gauss = FloatArray(2 * w + 1) { exp(-0.5 * ((it - w) * 32 / period).pow(2)).toFloat() }
        val local = FloatArray(n)
        for (t in 0 until n) {
            var s = 0f
            for (i in max(-w, -t)..min(w, n - 1 - t)) s += env[t + i] * gauss[i + w]
            local[t] = s
        }
        val lo = (period / 2).roundToInt(); val hi = (2 * period).roundToInt()
        val penalty = DoubleArray(hi + 1)
        if (lo <= hi) for (d in max(1, lo)..hi) penalty[d] = tightness * ln(d / period).pow(2)
        val score = DoubleArray(n); val back = IntArray(n) { -1 }
        for (t in 0 until n) {
            var best = Double.NEGATIVE_INFINITY; var from = -1
            val first = max(0, t - hi); val last = t - max(1, lo)
            if (last >= first) for (p in first..last) { val v = score[p] - penalty[t - p]; if (v > best) { best = v; from = p } }
            if (from >= 0 && best > 0) { score[t] = local[t] + best; back[t] = from } else score[t] = local[t].toDouble()
        }
        val peaks = (1 until n - 1).filter { score[it] > score[it - 1] && score[it] >= score[it + 1] }
        if (peaks.isEmpty()) return emptyList()
        val sorted = peaks.map { score[it] }.sorted()
        val median = sorted[sorted.size / 2]
        var t = peaks.lastOrNull { score[it] >= 0.5 * median } ?: return emptyList()
        val beats = mutableListOf(t)
        while (back[t] >= 0) { t = back[t]; beats.add(t) }
        beats.reverse()
        val rms = sqrt(beats.sumOf { (local[it] * local[it]).toDouble() } / beats.size)
        val floor = 0.5 * rms
        while (beats.isNotEmpty() && local[beats.first()] < floor) beats.removeAt(0)
        while (beats.isNotEmpty() && local[beats.last()] < floor) beats.removeAt(beats.size - 1)
        return beats
    }
}

/**
 * Beats of sound files, found once and kept in memory and on disk (cache/beats), like iOS's BeatCache.
 * `known` answers right away; `find` reads the file (MediaCodec, mono, resampled to 22050 Hz) and detects.
 */
object BeatCache {
    private val known = java.util.concurrent.ConcurrentHashMap<String, List<Double>>()
    @Volatile var folder: java.io.File? = null

    fun known(file: String): List<Double>? = known[file] ?: folder?.let { java.io.File(it, "$file.beats") }?.takeIf { it.exists() }
        ?.readText()?.split(',')?.mapNotNull { it.toDoubleOrNull() }?.also { known[file] = it }

    fun find(file: String): List<Double> {
        known(file)?.let { return it }
        val x = samples(cz.krechler.bombocut.model.Paths.mediaFile(file)) ?: return emptyList()
        val b = BeatDetector.beats(x)
        known[file] = b
        folder?.let { it.mkdirs(); java.io.File(it, "$file.beats").writeText(b.joinToString(",")) }
        return b
    }

    /** The file's sound as mono samples at 22050 Hz (linear resampling). */
    private fun samples(f: java.io.File): FloatArray? {
        val ex = android.media.MediaExtractor()
        try {
            ex.setDataSource(f.path)
            val track = (0 until ex.trackCount).firstOrNull {
                ex.getTrackFormat(it).getString(android.media.MediaFormat.KEY_MIME)?.startsWith("audio/") == true
            } ?: return null
            ex.selectTrack(track)
            val fmt = ex.getTrackFormat(track)
            val codec = android.media.MediaCodec.createDecoderByType(fmt.getString(android.media.MediaFormat.KEY_MIME)!!)
            codec.configure(fmt, null, null, 0); codec.start()
            var sr = fmt.getInteger(android.media.MediaFormat.KEY_SAMPLE_RATE)
            var ch = fmt.getInteger(android.media.MediaFormat.KEY_CHANNEL_COUNT)
            val mono = ArrayList<Float>()
            val info = android.media.MediaCodec.BufferInfo()
            var inDone = false; var outDone = false
            while (!outDone) {
                if (!inDone) {
                    val i = codec.dequeueInputBuffer(10_000)
                    if (i >= 0) {
                        val n = ex.readSampleData(codec.getInputBuffer(i)!!, 0)
                        if (n < 0) { codec.queueInputBuffer(i, 0, 0, 0, android.media.MediaCodec.BUFFER_FLAG_END_OF_STREAM); inDone = true }
                        else { codec.queueInputBuffer(i, 0, n, ex.sampleTime, 0); ex.advance() }
                    }
                }
                val o = codec.dequeueOutputBuffer(info, 10_000)
                if (o == android.media.MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    codec.outputFormat.let { sr = it.getInteger(android.media.MediaFormat.KEY_SAMPLE_RATE); ch = it.getInteger(android.media.MediaFormat.KEY_CHANNEL_COUNT) }
                } else if (o >= 0) {
                    val buf = codec.getOutputBuffer(o)!!.order(java.nio.ByteOrder.nativeOrder()).asShortBuffer()
                    val frames = info.size / 2 / ch
                    for (fr in 0 until frames) {
                        var m = 0f
                        for (k in 0 until ch) m += buf.get(fr * ch + k) / 32768f
                        mono.add(m / ch)
                    }
                    codec.releaseOutputBuffer(o, false)
                    if (info.flags and android.media.MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) outDone = true
                }
            }
            codec.stop(); codec.release()
            if (mono.isEmpty()) return null
            val ratio = sr / BeatDetector.sampleRate
            val n = (mono.size / ratio).toInt()
            return FloatArray(n) { i ->
                val p = i * ratio; val a = p.toInt(); val t = (p - a).toFloat()
                val x0 = mono[a]; val x1 = if (a + 1 < mono.size) mono[a + 1] else x0
                x0 + (x1 - x0) * t
            }
        } catch (e: Exception) { return null } finally { ex.release() }
    }
}

/** This sound's beats on the timeline (iOS AudioItem.timelineBeats): only while Beats is on and they're known. */
val cz.krechler.bombocut.model.AudioItem.timelineBeats: List<Double> get() {
    if (beatsOn != true) return emptyList()
    val b = BeatCache.known(file) ?: return emptyList()
    val sp = maxOf(speed, 0.01)
    return b.mapNotNull { s -> val t = start + (s - inPoint) / sp; if (t >= start - 1e-6 && t <= end + 1e-6) t else null }
}
