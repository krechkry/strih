package cz.krechler.bombocut

import cz.krechler.bombocut.editor.EditorModel
import cz.krechler.bombocut.model.BomboJson
import cz.krechler.bombocut.model.Project
import cz.krechler.bombocut.model.followFootage
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import java.util.UUID

/**
 * shared/parity/edits.json: the rich project after split, delete, trim, move and a speed change on iOS, with
 * captions, overlays and sounds following their footage. Android does the same edits and must end up with the
 * same project. (New clip ids from a split are random on both sides: they're matched by position.)
 */
class EditParityTest {
    @Serializable data class EditCase(val name: String, val output: String)

    private fun file(n: String) = File("../../shared/parity/$n").also { assumeTrue("fixtures not written yet", it.exists()) }

    private val rich: Project by lazy {
        val cases: List<ProjectParityTest.ProjectCase> = Json.decodeFromString(file("projects.json").readText())
        BomboJson.decodeFromString(Project.serializer(), cases.first { it.name == "rich" }.input)
    }

    private fun edited(change: (Project) -> Project): Project = change(rich).followFootage(rich).normalizeOverlays().cleanStacks()

    private fun replaced(p: Project, i: Int, a: cz.krechler.bombocut.model.Clip) = p.copy(clips = p.clips.toMutableList().also { it[i] = a })

    @Test fun editsLikeTheIPhone() {
        val cases: List<EditCase> = Json.decodeFromString(file("edits.json").readText())
        for (c in cases) {
            val want = BomboJson.decodeFromString(Project.serializer(), c.output)
            var got = when (c.name) {
                "split" -> edited { p ->
                    val cl = p.clips[1]
                    val (a, b) = EditorModel.clipHalves(cl, 6.0)!!
                    replaced(p, 1, a).copy(clips = replaced(p, 1, a).clips.toMutableList().also { it.add(2, b) }).joinStack(b.id, cl.id)
                }
                "split-curve" -> edited { p ->
                    val (a, b) = EditorModel.clipHalves(p.clips[0], 3.5)!!
                    replaced(p, 0, a).copy(clips = replaced(p, 0, a).clips.toMutableList().also { it.add(1, b) })
                }
                "delete" -> edited { p -> p.copy(clips = p.clips.drop(1)) }
                "trim" -> edited { p -> replaced(p, 2, p.clips[2].copy(outPoint = 3.0)) }
                "move" -> edited { p ->
                    val l = p.clips.toMutableList(); val cl = l.removeAt(3); l.add(0, cl)
                    p.copy(clips = l).leaveStackIfMovedAway(cl.id)
                }
                "speed" -> edited { p -> replaced(p, 1, p.clips[1].copy(speed = 1.0)) }
                else -> throw AssertionError("unknown edit ${c.name}")
            }
            // split pieces get random ids on both sides: take iOS's, so the rest can be compared exactly
            val ids = HashMap<UUID, UUID>()
            got.clips.zip(want.clips).forEach { (g, w) -> if (g.id != w.id) ids[g.id] = w.id }
            got = got.copy(
                clips = got.clips.map { it.copy(id = ids[it.id] ?: it.id) },
                stacks = got.stacks.map { s -> s.copy(clipIDs = s.clipIDs.map { ids[it] ?: it }) },
                modified = want.modified,
            )
            val gotJson = BomboJson.encodeToJsonElement(Project.serializer(), got)
            ProjectParityTest().sameJson(Json.parseToJsonElement(c.output), gotJson, c.name)
        }
    }
}
