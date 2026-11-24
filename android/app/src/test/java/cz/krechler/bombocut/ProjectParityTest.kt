package cz.krechler.bombocut

import cz.krechler.bombocut.model.BomboJson
import cz.krechler.bombocut.model.Project
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import org.junit.Assert.assertEquals
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import kotlin.math.abs

/**
 * shared/parity/projects.json: projects (and old-format JSON) read and written by the iPhone app.
 * Android must read the same input, write the same JSON and put the clips at the same times.
 */
class ProjectParityTest {
    @Serializable data class ProjectCase(
        val name: String, val input: String, val output: String, val duration: Double,
        val clipStarts: List<Double>, val clipDurations: List<Double>, val overlayTracks: List<Int>,
        val clipIndexAt: List<Double>, val clipIndex: List<Int>,
    )

    private val cases: List<ProjectCase> by lazy {
        val f = File("../../shared/parity/projects.json")
        assumeTrue("fixtures not written yet", f.exists())
        Json.decodeFromString(f.readText())
    }

    /** Same JSON, numbers within 1e-9 (relative), key order ignored. */
    private fun same(want: JsonElement, got: JsonElement, path: String) {
        when (want) {
            is JsonObject -> {
                val g = got as? JsonObject ?: throw AssertionError("$path: iOS has an object, Android $got")
                if (want.keys != g.keys) throw AssertionError("$path: keys differ, iOS ${want.keys - g.keys} only, Android ${g.keys - want.keys} only")
                for (k in want.keys) same(want[k]!!, g[k]!!, "$path.$k")
            }
            is JsonArray -> {
                val g = got as? JsonArray ?: throw AssertionError("$path: iOS has an array, Android $got")
                if (want.size != g.size) throw AssertionError("$path: iOS ${want.size} items, Android ${g.size}")
                want.indices.forEach { same(want[it], g[it], "$path[$it]") }
            }
            is JsonPrimitive -> {
                val g = got as? JsonPrimitive ?: throw AssertionError("$path: iOS $want, Android $got")
                if (want is JsonNull || g is JsonNull) { if (want != g) throw AssertionError("$path: iOS $want, Android $g"); return }
                val wb = want.booleanOrNull
                if (!want.isString && wb != null) { if (wb != g.booleanOrNull) throw AssertionError("$path: iOS $want, Android $g"); return }
                val wn = if (want.isString) null else want.doubleOrNull
                if (wn != null) {
                    val gn = g.doubleOrNull ?: throw AssertionError("$path: iOS $wn, Android $g")
                    if (abs(wn - gn) > 1e-9 * maxOf(1.0, abs(wn))) throw AssertionError("$path: iOS $wn, Android $gn")
                    return
                }
                if (want.content != g.content) throw AssertionError("$path: iOS \"${want.content}\", Android \"${g.content}\"")
            }
        }
    }

    @Test fun readsAndWritesLikeTheIPhone() {
        for (c in cases) {
            val p = BomboJson.decodeFromString(Project.serializer(), c.input)
            val out = BomboJson.encodeToJsonElement(Project.serializer(), p)
            same(Json.parseToJsonElement(c.output), out, c.name)
            // and Android reads its own output back to the same project
            assertEquals(c.name, p, BomboJson.decodeFromJsonElement(Project.serializer(), out))
        }
    }

    @Test fun timelineLikeTheIPhone() {
        for (c in cases) {
            val p = BomboJson.decodeFromString(Project.serializer(), c.input)
            fun near(w: Double, g: Double, what: String) { if (abs(w - g) > 1e-9 * maxOf(1.0, abs(w))) throw AssertionError("${c.name} $what: iOS $w, Android $g") }
            near(c.duration, p.duration, "duration")
            assertEquals("${c.name} clips", c.clipStarts.size, p.clips.size)
            c.clipStarts.zip(p.clipStarts).forEachIndexed { i, (w, g) -> near(w, g, "start of clip $i") }
            c.clipDurations.zip(p.clips.map { it.duration }).forEachIndexed { i, (w, g) -> near(w, g, "length of clip $i") }
            assertEquals("${c.name} overlay rows", c.overlayTracks, p.overlays.map { it.track ?: -1 })
            c.clipIndexAt.forEachIndexed { i, t -> assertEquals("${c.name} clip at $t", c.clipIndex[i], p.clipIndex(t)?.first ?: -1) }
        }
    }
}
