package cz.krechler.bombocut

import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.GainProcessor
import cz.krechler.bombocut.engine.CompositionBuilder
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Volume and fades through Media3's GainProcessor. It loops on "unity until" answers: one that didn't move past
 * a unity sample froze the preview and the export at the first sample of a fade-out (the transitions' sound
 * crossfade made that land exactly on a sample).
 */
class GainTest {
    private val rate = 48_000

    @Test fun unityAlwaysMovesOn() {
        for ((volume, fades) in listOf(1.0 to (0.0 to 0.5), 1.0 to (0.5 to 0.0), 1.0 to (0.3 to 0.4), 0.5 to (0.0 to 0.5), 1.5 to (0.0 to 0.5))) {
            val p = CompositionBuilder.gainProvider(volume, fades, 3.0)
            for (pos in 0L until (3.2 * rate).toLong()) {
                if (p.getGainFactorAtSamplePosition(pos, rate) != 1f) continue
                val end = p.isUnityUntil(pos, rate)
                assertTrue("volume $volume fades $fades at $pos: unity until $end", end == C.TIME_END_OF_SOURCE || end > pos)
            }
        }
    }

    @Test(timeout = 10_000) fun fadeOutRunsThroughTheProcessor() {
        val gp = CompositionBuilder.gain(1.0, 0.0 to 0.5, 3.0) as GainProcessor
        gp.configure(AudioProcessor.AudioFormat(rate, 1, C.ENCODING_PCM_16BIT))
        gp.flush()
        val frames = 3 * rate
        val input = ByteBuffer.allocateDirect(frames * 2).order(ByteOrder.nativeOrder())
        repeat(frames) { input.putShort(10_000) }
        input.flip()
        var out = 0
        val last = ShortArray(1)
        while (input.hasRemaining()) {
            gp.queueInput(input)
            val o = gp.output
            out += o.remaining() / 2
            while (o.hasRemaining()) last[0] = o.short
        }
        assertEquals(frames, out)
        // the start is untouched, the last sample is faded nearly to silence
        assertTrue("end faded: ${last[0]}", last[0] < 100)
    }
}
