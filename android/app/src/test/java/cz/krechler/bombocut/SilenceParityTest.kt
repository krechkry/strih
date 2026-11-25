package cz.krechler.bombocut

import cz.krechler.bombocut.engine.Silence
import cz.krechler.bombocut.model.BomboJson
import cz.krechler.bombocut.model.Clip
import cz.krechler.bombocut.model.Project
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import kotlin.math.abs

/**
 * shared/parity/silence.json: the iPhone's Remove silence on the same loudness (auto threshold, quiet stretches,
 * what gets cut) and the rich project's clips cut into the pieces that stay (new piece ids are random: the first
 * piece keeps the clip's id, the rest are compared by everything else).
 */
class SilenceParityTest {
    @Serializable data class QuietCase(val levels: List<Float>, val auto: Double, val minSilence: Double,
                                       val quiet: List<List<Double>>, val length: Double, val cuts: List<List<Double>>)
    @Serializable data class PiecesCase(val clipIndex: Int, val cuts: List<List<Double>>, val fade: Double, val pieces: List<Clip>? = null)
    @Serializable data class Fixture(val quiet: List<QuietCase>, val pieces: List<PiecesCase>)

    private fun file(n: String) = File("../../shared/parity/$n").also { assumeTrue("fixtures not written yet", it.exists()) }
    private val fixture by lazy { BomboJson.decodeFromString(Fixture.serializer(), file("silence.json").readText()) }
    private val rich: Project by lazy {
        val cases: List<ProjectParityTest.ProjectCase> = Json.decodeFromString(file("projects.json").readText())
        BomboJson.decodeFromString(Project.serializer(), cases.first { it.name == "rich" }.input)
    }

    private fun near(a: Double, b: Double) = abs(a - b) < 1e-9
    private fun r9(x: Double) = Math.round(x * 1e9) / 1e9
    private fun Clip.r() = copy(inPoint = r9(inPoint), outPoint = r9(outPoint), fadeIn = r9(fadeIn), fadeOut = r9(fadeOut),
                                speedCurve = speedCurve?.map { it.copy(t = r9(it.t), v = r9(it.v)) })

    @Test fun findsTheSamePauses() {
        for ((n, c) in fixture.quiet.withIndex()) {
            val auto = Silence.autoThreshold(c.levels)
            assert(near(auto, c.auto)) { "case $n: threshold $auto, iPhone ${c.auto}" }
            val q = Silence.quiet(c.levels, auto, c.minSilence)
            assertEquals("case $n: quiet", c.quiet.map { it[0] to it[1] }, q.map { it.start to it.endInclusive })
            val cuts = Silence.cuts(q, c.length, Silence.Settings())
            assertEquals("case $n: cuts", c.cuts.size, cuts.size)
            for ((w, g) in c.cuts.zip(cuts)) assert(near(w[0], g.start) && near(w[1], g.endInclusive)) { "case $n: cut $g, iPhone $w" }
        }
    }

    @Test fun cutsTheClipLikeTheIPhone() {
        for ((n, c) in fixture.pieces.withIndex()) {
            val clip = rich.clips[c.clipIndex]
            val got = Silence.pieces(clip, c.cuts.map { it[0]..it[1] }, c.fade)
            val want = c.pieces
            assertEquals("case $n: pieces or none", want == null, got == null)
            if (want == null || got == null) continue
            assertEquals("case $n: count", want.size, got.size)
            assertEquals("case $n: first keeps the id", want[0].id, got[0].id)
            for ((w, g) in want.zip(got)) {
                // ids of the new pieces are random on both sides; the last bit of a double may differ (curve math)
                assertEquals("case $n", w.copy(id = g.id).r(), g.r())
            }
        }
    }
}
