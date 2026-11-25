package cz.krechler.bombocut

import cz.krechler.bombocut.engine.Transcriber
import cz.krechler.bombocut.engine.Transcriber.TokenTiming
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.PI
import kotlin.math.sin

/** Captions on Android: word pieces into words (Swift Transcriber.words) and long audio cut at quiet spots. */
class TranscriberTest {
    @Test fun piecesBecomeWords() {
        val t = listOf(
            TokenTiming("▁Ah", 0.10, 0.20), TokenTiming("oj", 0.20, 0.32),
            TokenTiming("▁li", 0.40, 0.50), TokenTiming("di", 0.50, 0.62), TokenTiming(",", 0.62, 0.66),
            TokenTiming("▁jak", 0.80, 0.95), TokenTiming("▁se", 0.90, 1.10), TokenTiming("▁máte", 1.10, 1.50), TokenTiming("?", 1.50, 1.52),
        )
        val w = Transcriber.words(t, duration = 1.45)
        assertEquals(listOf("Ahoj", "lidi,", "jak", "se", "máte?"), w.map { it.text })
        assertEquals(0.10, w[0].start, 1e-9); assertEquals(0.32, w[0].end, 1e-9)
        // punctuation doesn't stretch the word
        assertEquals(0.62, w[1].end, 1e-9)
        // overlapping words end where the next starts; nothing runs past the end
        assertEquals(0.90, w[2].end, 1e-9)
        assertTrue(w.last().end <= 1.45 + 1e-9)
    }

    @Test fun leadingPunctuationStartsAWord() {
        val w = Transcriber.words(listOf(TokenTiming("„", 0.0, 0.05), TokenTiming("Ano", 0.05, 0.3)), 1.0)
        assertEquals(listOf("„Ano"), w.map { it.text })
    }

    @Test fun longAudioIsCutInQuietSpots() {
        val rate = Transcriber.RATE
        // 70 s of "speech" (a tone) with short pauses every 5 s and one long pause around 37 s
        val x = FloatArray(70 * rate) { i ->
            val s = i.toDouble() / rate
            val pause = (s % 5.0) > 4.85 || s in 36.6..37.4
            if (pause) 0f else (0.3 * sin(2 * PI * 220 * s)).toFloat()
        }
        val p = Transcriber.pieces(x, 0, x.size)
        assertEquals(0, p.first().first); assertEquals(x.size, p.last().second)
        for (i in 1 until p.size) assertEquals(p[i - 1].second, p[i].first)
        for ((a, b) in p) assertTrue("piece ${a.toDouble() / rate}..${b.toDouble() / rate}", b - a <= 28 * rate)
        // every cut lands in a pause
        for ((_, b) in p.dropLast(1)) {
            val s = b.toDouble() / rate
            assertTrue("cut at $s", (s % 5.0) > 4.8 || s in 36.5..37.5)
        }
        assertTrue(Transcriber.pieces(FloatArray(10 * rate), 0, 10 * rate).size == 1)
    }

    @Test fun resampling() {
        val x = FloatArray(48_000) { 1f }
        assertEquals(16_000, Transcriber.resample(x, 48_000, 16_000).size)
    }
}
