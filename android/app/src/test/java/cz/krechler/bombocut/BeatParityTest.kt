package cz.krechler.bombocut

import cz.krechler.bombocut.engine.BeatDetector
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.floor
import kotlin.math.sin

/**
 * shared/parity/beats.json: the iPhone's beats and tempo for the same synthetic drum loops (made here the same
 * way, LCG noise included). Beats must land within one 11.6 ms step, the tempo within 0.5 BPM.
 */
class BeatParityTest {
    @Serializable data class BeatCase(val bpm: Double, val offset: Double, val seconds: Double, val tempo: Double? = null, val beats: List<Double>)

    private fun drumLoop(bpm: Double, offset: Double, seconds: Double): FloatArray {
        val sr = BeatDetector.sampleRate
        val n = (seconds * sr).toInt()
        val period = 60 / bpm
        var state = 12345L
        return FloatArray(n) { i ->
            val t = i / sr
            state = (state * 1103515245L + 12345L) and 0x7fffffffL
            val noise = state / 2147483648.0 * 2 - 1
            var v = 0.0
            if (t >= offset) {
                val k = floor((t - offset) / period)
                val dt = t - offset - k * period
                v += sin(2 * PI * 55 * dt) * exp(-dt * 25)
                val dh = dt - period / 2
                if (dh >= 0 && dh < 0.03) v += noise * exp(-dh * 150) * 0.3
            }
            (v * 0.8).toFloat()
        }
    }

    @Test fun beatsLikeTheIPhone() {
        val f = File("../../shared/parity/beats.json")
        assumeTrue("fixtures not written yet", f.exists())
        val cases: List<BeatCase> = Json.decodeFromString(f.readText())
        val step = BeatDetector.hop / BeatDetector.sampleRate
        for (c in cases) {
            val x = drumLoop(c.bpm, c.offset, c.seconds)
            val tempo = BeatDetector.tempo(x)
            assertEquals("${c.bpm} BPM: tempo found", c.tempo != null, tempo != null)
            if (c.tempo != null && tempo != null) assert(abs(c.tempo - tempo) < 0.5) { "${c.bpm} BPM: tempo $tempo, iPhone ${c.tempo}" }
            val got = BeatDetector.beats(x)
            assertEquals("${c.bpm} BPM: beat count (got $got, iPhone ${c.beats})", c.beats.size, got.size)
            for ((w, g) in c.beats.zip(got)) assert(abs(w - g) <= step + 1e-9) { "${c.bpm} BPM: beat at $g, iPhone $w" }
        }
    }
}
