package cz.krechler.bombocut

import cz.krechler.bombocut.model.BomboJson
import cz.krechler.bombocut.model.Project
import cz.krechler.bombocut.model.ProjectFile
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.file.Files
import java.util.zip.ZipInputStream

/**
 * A .bbc written on Android has what the iPhone's ProjectFile.unpack reads (bombocut.json with every Manifest key,
 * project.json, Media/<name>), and reading it back gives the same project and the same videos.
 */
class ProjectFileTest {
    private val rich: Project by lazy {
        val f = File("../../shared/parity/projects.json")
        assumeTrue("fixtures not written yet", f.exists())
        val cases: List<ProjectParityTest.ProjectCase> = Json.decodeFromString(f.readText())
        BomboJson.decodeFromString(Project.serializer(), cases.first { it.name == "rich" }.input)
    }

    @Test fun roundTripsAndMatchesTheIPhoneLayout() {
        val src = Files.createTempDirectory("media").toFile()
        val used = rich.mediaFiles.toList()
        used.forEachIndexed { i, n -> File(src, n).writeBytes(ByteArray(1000 + i) { (it * 7 + i).toByte() }) }

        val zip = ByteArrayOutputStream().also { ProjectFile.pack(rich, it) { n -> File(src, n) } }.toByteArray()

        // the layout iOS reads
        val names = mutableListOf<String>()
        var manifest = ""
        ZipInputStream(ByteArrayInputStream(zip)).use { z ->
            while (true) {
                val e = z.nextEntry ?: break
                names += e.name
                if (e.name == "bombocut.json") manifest = z.readBytes().decodeToString()
            }
        }
        assertTrue("bombocut.json first", names.first() == "bombocut.json")
        assertTrue("project.json", "project.json" in names)
        assertEquals(used.map { "Media/$it" }.sorted(), names.filter { it.startsWith("Media/") }.sorted())
        val keys = Json.parseToJsonElement(manifest).jsonObject.keys
        for (k in listOf("format", "app", "name", "made", "media", "fonts", "luts", "bytes")) assertTrue("manifest has $k", k in keys)

        // and back
        val dest = Files.createTempDirectory("dest").toFile()
        val temp = Files.createTempDirectory("temp").toFile()
        val r = ProjectFile.unpack(ByteArrayInputStream(zip), temp) { n -> File(dest, n) }
        assertTrue(r is ProjectFile.Unpacked.Ok)
        assertEquals(rich, (r as ProjectFile.Unpacked.Ok).project)
        for (n in used) assertTrue("video $n", File(src, n).readBytes().contentEquals(File(dest, n).readBytes()))
    }

    @Test fun refusesWhatIsNotAProject() {
        val zip = ByteArrayOutputStream().also { out ->
            java.util.zip.ZipOutputStream(out).use { z -> z.putNextEntry(java.util.zip.ZipEntry("hello.txt")); z.write("hi".toByteArray()); z.closeEntry() }
        }.toByteArray()
        val r = ProjectFile.unpack(ByteArrayInputStream(zip), Files.createTempDirectory("t").toFile()) { File(it) }
        assertEquals(ProjectFile.Unpacked.NotAProject, r)
    }
}
