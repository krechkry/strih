package cz.krechler.bombocut

import cz.krechler.bombocut.app.Fmt
import cz.krechler.bombocut.model.BomboJson
import cz.krechler.bombocut.model.Canvas
import cz.krechler.bombocut.model.Fade
import cz.krechler.bombocut.model.Retime
import cz.krechler.bombocut.model.SpeedCurve
import cz.krechler.bombocut.model.SpeedPoint
import kotlinx.serialization.Serializable
import org.junit.Assert.assertEquals
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import kotlin.math.abs

/** shared/parity/timing.json, written by the iPhone app's ParityFixtures test: Kotlin must agree. */
class TimingParityTest {
    @Serializable data class CurveCase(val pts: List<SpeedPoint>, val us: List<Double>, val values: List<Double>)
    @Serializable data class RetimeCase(
        val inPoint: Double, val length: Double, val curve: List<SpeedPoint>? = null, val speed: Double, val factor: Double,
        val segs: List<List<Double>>, val outDuration: Double,
        val locals: List<Double>, val sources: List<Double>, val speeds: List<Double>,
        val sourcePoints: List<Double>, val localsAt: List<Double>,
    )
    @Serializable data class FadeCase(val fadeIn: Double, val fadeOut: Double, val length: Double, val fit: List<Double>, val gains: List<Double>)
    @Serializable data class CanvasCase(val ratioW: Double, val ratioH: Double, val label: String, val size1080: List<Int>, val size720: List<Int>)
    @Serializable data class FmtCase(val value: Double, val speed: String, val time: String, val duration: String, val delta: String)
    @Serializable data class Timing(val curves: List<CurveCase>, val retimes: List<RetimeCase>, val fades: List<FadeCase>,
                                    val canvases: List<CanvasCase>, val fmt: List<FmtCase>)

    private val timing: Timing by lazy {
        val f = File("../../shared/parity/timing.json")
        assumeTrue("fixtures not written yet", f.exists())
        BomboJson.decodeFromString(Timing.serializer(), f.readText())
    }

    private fun near(want: Double, got: Double, what: String) {
        val tol = 1e-9 * maxOf(1.0, abs(want))
        if (abs(want - got) > tol) throw AssertionError("$what: iOS $want, Android $got")
    }

    @Test fun speedCurveValues() {
        for ((c, case) in timing.curves.withIndex()) for ((i, u) in case.us.withIndex()) {
            near(case.values[i], SpeedCurve.value(case.pts, u), "curve $c at $u")
        }
    }

    @Test fun retimePiecesAndMapping() {
        for ((k, c) in timing.retimes.withIndex()) {
            val rt = Retime(c.inPoint, c.length, c.curve, c.speed, c.factor)
            assertEquals("retime $k: piece count", c.segs.size, rt.segs.size)
            for ((i, s) in c.segs.withIndex()) {
                val g = rt.segs[i]
                near(s[0], g.src0, "retime $k seg $i src0"); near(s[1], g.srcLen, "retime $k seg $i srcLen")
                near(s[2], g.out0, "retime $k seg $i out0"); near(s[3], g.outLen, "retime $k seg $i outLen")
            }
            near(c.outDuration, rt.outDuration, "retime $k duration")
            for ((i, t) in c.locals.withIndex()) {
                near(c.sources[i], rt.source(t), "retime $k source at $t")
                near(c.speeds[i], rt.speed(t), "retime $k speed at $t")
            }
            for ((i, x) in c.sourcePoints.withIndex()) near(c.localsAt[i], rt.local(x), "retime $k local at $x")
        }
    }

    @Test fun fades() {
        for (c in timing.fades) {
            val f = Fade.fit(c.fadeIn, c.fadeOut, c.length)
            near(c.fit[0], f.first, "fade in"); near(c.fit[1], f.second, "fade out")
            val step = maxOf(c.length / 10, 0.1)
            // Swift's stride: start + i * step (no running sum)
            for ((i, want) in c.gains.withIndex()) near(want, Fade.gain(i * step, c.length, f), "gain $i")
        }
    }

    @Test fun canvases() {
        for (c in timing.canvases) {
            val cv = Canvas(c.ratioW, c.ratioH)
            assertEquals(c.label, cv.label)
            assertEquals(c.size1080, cv.size(1080).toList())
            assertEquals(c.size720, cv.size(720).toList())
        }
    }

    @Test fun formatting() {
        for (c in timing.fmt) {
            assertEquals("speed ${c.value}", c.speed, Fmt.speed(c.value))
            assertEquals("time ${c.value}", c.time, Fmt.time(c.value))
            assertEquals("duration ${c.value}", c.duration, Fmt.duration(c.value))
            assertEquals("delta ${c.value}", c.delta, Fmt.delta(c.value))
        }
    }
}
