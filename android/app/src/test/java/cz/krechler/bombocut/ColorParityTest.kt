package cz.krechler.bombocut

import cz.krechler.bombocut.engine.LookMath
import cz.krechler.bombocut.model.BomboJson
import cz.krechler.bombocut.model.Effects
import kotlinx.serialization.Serializable
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * shared/parity/colors.json: 125 colors through each Adjust light / color slider on the iPhone (Core Image).
 * Writes build/color-report.txt (the largest difference per slider, in 8-bit levels); fails over the tolerance.
 * Temperature / tint use Core Image's own white balance: a looser tolerance until it is calibrated.
 */
class ColorParityTest {
    @Serializable data class ColorCase(val name: String, val effects: Effects, val output: List<List<Int>>)
    @Serializable data class ColorFixture(val input: List<List<Int>>, val cases: List<ColorCase>)

    @Test fun adjustLikeTheIPhone() {
        val f = File("../../shared/parity/colors.json")
        assumeTrue("fixtures not written yet", f.exists())
        val fx = BomboJson.decodeFromString(ColorFixture.serializer(), f.readText())
        val report = StringBuilder()
        val bad = mutableListOf<String>()
        for (c in fx.cases) {
            var worst = 0; var at = ""
            fx.input.forEachIndexed { k, rgb ->
                val got = LookMath.color(DoubleArray(3) { rgb[it] / 255.0 }, c.effects).map { (it * 255).roundToInt() }
                val d = (0..2).maxOf { abs(got[it] - c.output[k][it]) }
                if (d > worst) { worst = d; at = "$rgb -> iOS ${c.output[k]}, Android $got" }
            }
            report.append("${c.name}: $worst levels${if (worst > 0) "  (worst $at)" else ""}\n")
            val tol = if (c.name.startsWith("temperature") || c.name.startsWith("tint") || c.name == "combo") 40 else 3
            if (worst > tol) bad += "${c.name} off by $worst"
        }
        File("build").mkdirs()
        File("build/color-report.txt").writeText(report.toString())
        println(report)
        if (bad.isNotEmpty()) throw AssertionError(bad.joinToString("; ") + "\n" + report)
    }
}
