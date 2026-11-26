// Ported from Bombocut/Engine/Speech.swift (iOS a28b16c), Transcriber + SpeechEngine. Same workflow as iOS: the
// model once, then offline: the timeline's sound (mixed like the export), the speech model, word pieces with their
// times grouped into words (`words` is 1:1), then CaptionCutter (already ported) makes the lines.
// Reworked: the sound is exported by Media3 Transformer as 16 kHz mono (iOS: AVAssetExportSession m4a), the model
// runs through sherpa-onnx (iOS: FluidAudio), and long audio is cut at quiet spots into pieces of about 20 s (sherpa's
// offline recognizer listens to one piece at once). Not yet: SpellCheck (iOS UITextChecker), typed names.
@file:OptIn(androidx.media3.common.util.UnstableApi::class)
package cz.krechler.bombocut.engine

import android.content.Context
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import androidx.media3.common.MimeTypes
import androidx.media3.common.audio.ChannelMixingAudioProcessor
import androidx.media3.common.audio.ChannelMixingMatrix
import androidx.media3.common.audio.SonicAudioProcessor
import androidx.media3.transformer.Composition
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.Transformer
import com.k2fsa.sherpa.onnx.OfflineModelConfig
import com.k2fsa.sherpa.onnx.OfflineRecognizer
import com.k2fsa.sherpa.onnx.OfflineRecognizerConfig
import com.k2fsa.sherpa.onnx.OfflineTransducerModelConfig
import cz.krechler.bombocut.model.CaptionWord
import cz.krechler.bombocut.model.Project
import cz.krechler.bombocut.model.SpellCheck
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException
import java.nio.ByteOrder
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlin.math.max
import kotlin.math.min

object Transcriber {
    /** What a caption run is doing (iOS Transcriber.Phase). */
    sealed class Phase {
        data class Downloading(val fraction: Double) : Phase()
        data object PreparingAudio : Phase()
        data object LoadingModel : Phase()
        data class Listening(val fraction: Double) : Phase()
    }

    /** One word piece from the model, timeline seconds (FluidAudio's TokenTiming). */
    data class TokenTiming(val token: String, val startTime: Double, val endTime: Double, val confidence: Double = 1.0)

    const val RATE = 16_000

    /**
     * Words heard on the project's timeline. `range`: just this stretch (word times stay timeline seconds).
     * `phase` is called on the calling (main) thread's dispatcher.
     */
    suspend fun run(context: Context, project: Project, range: ClosedFloatingPointRange<Double>? = null,
                    language: String = "", names: String = "", phase: (Phase) -> Unit): List<CaptionWord> {
        if (!SpeechModel.isReady) {
            // the app's one download (the Storage screen shows the same); paused, this keeps waiting
            SpeechDownload.await { st ->
                when (st) {
                    is SpeechDownload.State.Downloading -> phase(Phase.Downloading(st.fraction))
                    is SpeechDownload.State.Paused -> phase(Phase.Downloading(st.fraction))
                    else -> {}
                }
            }
        }
        phase(Phase.PreparingAudio)
        val file = exportAudio(context, project)
        val samples = try { withContext(Dispatchers.IO) { readPcm(file) } } finally { file.delete() }
        val lo = range?.let { (it.start * RATE).toInt().coerceIn(0, samples.size) } ?: 0
        val hi = range?.let { (it.endInclusive * RATE).toInt().coerceIn(lo, samples.size) } ?: samples.size
        phase(Phase.LoadingModel)
        val recognizer = withContext(Dispatchers.IO) { Engine.recognizer() }
        val main = android.os.Handler(android.os.Looper.getMainLooper())
        val tokens = withContext(Dispatchers.Default) {
            val pieces = pieces(samples, lo, hi)
            val out = ArrayList<TokenTiming>()
            pieces.forEachIndexed { k, (a, b) ->
                val f = (k + 0.1) / pieces.size
                main.post { phase(Phase.Listening(f)) }
                out += listen(recognizer, samples, a, b)
            }
            out
        }
        phase(Phase.Listening(1.0))
        return tidy(context, words(tokens, duration = hi.toDouble() / RATE), language, names)
    }

    /**
     * After the model, like iOS: the names you typed win over sound-alikes, then for Czech the Polish / Slovak
     * spellings go Czech. (iOS's third step, unsure words to the dictionary, needs the model's confidence: see SpellCheck.)
     */
    suspend fun tidy(context: Context, heard: List<CaptionWord>, language: String, names: String): List<CaptionWord> {
        val typed = SpellCheck.splitNames(names)
        var words = SpellCheck.applyNames(heard, typed)
        if (language == "cs") {
            val known = withContext(Dispatchers.IO) { CzechWords.load(context) }
            words = SpellCheck.czech(words, typed.map { it.lowercase() }.toSet()) { it in known }
        }
        return words
    }

    /** The timeline's sound as a 16 kHz mono .m4a in the cache (Transformer, the same mix as the export). */
    private suspend fun exportAudio(context: Context, project: Project): File {
        val mono = ChannelMixingAudioProcessor().apply {
            // every channel an equal share (Media3's own defaults only go up to stereo)
            for (ch in 1..8) putChannelMixingMatrix(ChannelMixingMatrix(ch, 1, FloatArray(ch) { 1f / ch }))
        }
        val rate = SonicAudioProcessor().apply { setOutputSampleRateHz(RATE) }
        val comp = CompositionBuilder.buildAudio(project, listOf(mono, rate)) ?: throw IOException("Nothing to listen to.")
        val out = File(context.cacheDir, "captions-${System.currentTimeMillis()}.m4a")
        return withContext(Dispatchers.Main) {
            suspendCancellableCoroutine { cont ->
                val t = Transformer.Builder(context)
                    .setAudioMimeType(MimeTypes.AUDIO_AAC)
                    .addListener(object : Transformer.Listener {
                        override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                            if (cont.isActive) cont.resume(out)
                        }
                        override fun onError(composition: Composition, exportResult: ExportResult, exportException: ExportException) {
                            if (cont.isActive) cont.resumeWithException(IOException("Could not read the audio.", exportException))
                        }
                    })
                    .build()
                t.start(comp, out.path)
                cont.invokeOnCancellation { t.cancel(); out.delete() }
            }
        }
    }

    /** Decodes the exported sound to floats, mono at 16 kHz (mixed down and resampled again if a codec changed it). */
    private fun readPcm(file: File): FloatArray {
        val ex = MediaExtractor()
        try {
            ex.setDataSource(file.path)
            val track = (0 until ex.trackCount).firstOrNull {
                ex.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
            } ?: return FloatArray(0)
            ex.selectTrack(track)
            val fmt = ex.getTrackFormat(track)
            val codec = MediaCodec.createDecoderByType(fmt.getString(MediaFormat.KEY_MIME)!!)
            codec.configure(fmt, null, null, 0)
            codec.start()
            var sr = fmt.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            var ch = fmt.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            var out = FloatArray(1 shl 20)
            var n = 0
            val info = MediaCodec.BufferInfo()
            var inputDone = false; var outputDone = false
            while (!outputDone) {
                if (!inputDone) {
                    val i = codec.dequeueInputBuffer(10_000)
                    if (i >= 0) {
                        val got = ex.readSampleData(codec.getInputBuffer(i)!!, 0)
                        if (got < 0) { codec.queueInputBuffer(i, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM); inputDone = true }
                        else { codec.queueInputBuffer(i, 0, got, ex.sampleTime, 0); ex.advance() }
                    }
                }
                val o = codec.dequeueOutputBuffer(info, 10_000)
                if (o == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    codec.outputFormat.let { sr = it.getInteger(MediaFormat.KEY_SAMPLE_RATE); ch = it.getInteger(MediaFormat.KEY_CHANNEL_COUNT) }
                } else if (o >= 0) {
                    val buf = codec.getOutputBuffer(o)!!.order(ByteOrder.nativeOrder()).asShortBuffer()
                    val frames = info.size / 2 / ch
                    if (n + frames > out.size) out = out.copyOf(max(out.size * 2, n + frames))
                    for (f in 0 until frames) {
                        var m = 0f
                        for (k in 0 until ch) m += buf.get(f * ch + k) / 32768f
                        out[n++] = m / ch
                    }
                    codec.releaseOutputBuffer(o, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) outputDone = true
                }
            }
            codec.stop(); codec.release()
            val pcm = out.copyOf(n)
            return if (sr == RATE) pcm else resample(pcm, sr, RATE)
        } finally { ex.release() }
    }

    /** Linear resampling (only when a decoder hands back another rate than the 16 kHz asked for). */
    fun resample(x: FloatArray, from: Int, to: Int): FloatArray {
        if (from == to || x.isEmpty()) return x
        val n = (x.size.toLong() * to / from).toInt()
        return FloatArray(n) { i ->
            val p = i.toDouble() * from / to
            val a = p.toInt().coerceAtMost(x.size - 1)
            val b = min(a + 1, x.size - 1)
            val f = (p - a).toFloat()
            x[a] * (1 - f) + x[b] * f
        }
    }

    /**
     * Cuts [lo, hi) into pieces of about 20 s (at most 28 s) at the quietest 0.3 s between 14 and 28 s, so no word
     * is cut in half and each piece fits the recognizer comfortably. Pure: unit tested.
     */
    fun pieces(x: FloatArray, lo: Int, hi: Int, target: Double = 20.0): List<Pair<Int, Int>> {
        val out = ArrayList<Pair<Int, Int>>()
        val minLen = (14.0 * RATE).toInt(); val maxLen = (28.0 * RATE).toInt()
        val hop = RATE / 100                           // 10 ms
        val win = 30                                    // 0.3 s of hops
        var a = lo
        while (hi - a > maxLen) {
            val from = a + minLen; val to = min(hi, a + maxLen)
            val hops = (to - from) / hop
            val energy = DoubleArray(hops) { h ->
                var s = 0.0; val o = from + h * hop
                for (i in o until min(o + hop, hi)) s += x[i] * x[i]
                s
            }
            var best = -1; var bestE = Double.MAX_VALUE
            var sum = 0.0
            for (h in 0 until hops) {
                sum += energy[h]
                if (h >= win) sum -= energy[h - win]
                if (h >= win - 1) {
                    // prefer quiet spots near the target length a little (ties go to about 20 s)
                    val mid = from + (h - win / 2) * hop
                    val bias = 1 + 0.15 * kotlin.math.abs((mid - a).toDouble() / RATE - target) / target
                    val e = sum * bias
                    if (e < bestE) { bestE = e; best = mid }
                }
            }
            val cut = if (best > a) best else a + (target * RATE).toInt()
            out.add(a to cut)
            a = cut
        }
        if (hi - a > RATE / 10) out.add(a to hi)
        return out
    }

    /** One piece through the model: its word pieces, timeline seconds. */
    private fun listen(r: OfflineRecognizer, x: FloatArray, a: Int, b: Int): List<TokenTiming> {
        val s = r.createStream()
        try {
            s.acceptWaveform(x.copyOfRange(a, b), RATE)
            r.decode(s)
            val res = r.getResult(s)
            val off = a.toDouble() / RATE
            val n = min(res.tokens.size, res.timestamps.size)
            return (0 until n).map { i ->
                val st = res.timestamps[i].toDouble()
                // TDT gives each piece's length; otherwise it lasts until the next one starts
                val d = res.durations.getOrNull(i)?.toDouble()?.takeIf { it > 0 }
                    ?: ((res.timestamps.getOrNull(i + 1)?.toDouble() ?: (st + 0.2)) - st)
                TokenTiming(res.tokens[i], off + st, off + st + max(d, 0.02))
            }
        } finally { s.release() }
    }

    /**
     * Word pieces -> words (Swift Transcriber.words, 1:1). A piece starting with a space (or SentencePiece's "▁")
     * begins a new word; punctuation pieces stick to the word before. Times come straight from the model.
     */
    fun words(tokens: List<TokenTiming>, duration: Double): List<CaptionWord> {
        val out = ArrayList<CaptionWord>()
        val conf = ArrayList<Double>()
        val limit = if (duration > 0) duration else Double.MAX_VALUE
        for (t in tokens) {
            var piece = t.token.replace("▁", " ")
            val startsWord = piece.startsWith(" ") || out.isEmpty()
            piece = piece.trim(' ')
            if (piece.isEmpty()) continue
            val s = min(max(t.startTime, 0.0), limit); val e = min(max(t.endTime, t.startTime), limit)
            val punct = piece.all { ".,!?…;:\"'«»„“”()-–".contains(it) }
            if (startsWord && !(punct && out.isNotEmpty())) {
                out.add(CaptionWord(piece, s, max(e, s + 0.04), t.confidence))
                conf.add(t.confidence)
            } else if (out.isNotEmpty()) {
                val i = out.size - 1
                conf[i] = min(conf[i], t.confidence)
                out[i] = out[i].copy(text = out[i].text + piece, end = if (!punct) max(out[i].end, e) else out[i].end, confidence = conf[i])
            }
        }
        // never overlapping, never past the end
        for (i in 0 until out.size - 1) if (out[i].end > out[i + 1].start) out[i] = out[i].copy(end = max(out[i].start + 0.02, out[i + 1].start))
        return out
    }

    /** Keeps the model loaded between caption runs (iOS SpeechEngine). */
    object Engine {
        @Volatile private var loaded: OfflineRecognizer? = null

        @Synchronized fun recognizer(): OfflineRecognizer {
            loaded?.let { return it }
            if (!SpeechModel.isReady) throw IOException("The speech model isn't downloaded yet.")
            val cfg = OfflineRecognizerConfig(
                modelConfig = OfflineModelConfig(
                    transducer = OfflineTransducerModelConfig(
                        encoder = SpeechModel.file("encoder.int8.onnx").path,
                        decoder = SpeechModel.file("decoder.int8.onnx").path,
                        joiner = SpeechModel.file("joiner.int8.onnx").path,
                    ),
                    tokens = SpeechModel.file("tokens.txt").path,
                    modelType = "nemo_transducer",
                    numThreads = max(1, min(4, Runtime.getRuntime().availableProcessors() - 1)),
                ),
                decodingMethod = "greedy_search",
            )
            cfg.featConfig.featureDim = 128
            return OfflineRecognizer(null, cfg).also { loaded = it }
        }

        @Synchronized fun unload() { loaded?.release(); loaded = null }
    }
}
