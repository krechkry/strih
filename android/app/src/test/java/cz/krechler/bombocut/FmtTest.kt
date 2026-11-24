package cz.krechler.bombocut

import cz.krechler.bombocut.app.Fmt
import cz.krechler.bombocut.app.Strings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.util.Locale

/** Formatting and strings exactly as on iOS. */
class FmtTest {
    @Test fun speedsLikeSwift() {
        assertEquals("2x", Fmt.speed(2.0))
        assertEquals("1.5x", Fmt.speed(1.5))
        assertEquals("0.25x", Fmt.speed(0.25))
        assertEquals("0.5x", Fmt.speed(0.5))
        assertEquals("12x", Fmt.speed(12.0))
    }

    @Test fun timesUseADotEvenInCzech() {
        val before = Locale.getDefault()
        Locale.setDefault(Locale.forLanguageTag("cs-CZ"))
        try {
            assertEquals("0:03.2", Fmt.time(3.2))
            assertEquals("1:05.0", Fmt.time(65.0))
            assertEquals("4.5s", Fmt.duration(4.5))
            assertEquals("2:05", Fmt.duration(125.0))
            assertEquals("+0.40s", Fmt.delta(0.4))
            assertEquals("−1.25s", Fmt.delta(-1.25))
        } finally { Locale.setDefault(before) }
    }

    @Test fun czechComesFromTheIosStrings() {
        val json = File("../../Bombocut/Localizable.xcstrings").readText()
        val cs = Strings.fromXcstrings(json, "cs")
        assertEquals("Duplikovat", cs.translate("Duplicate"))
        assertEquals("Odstranit ticho", cs.translate("Remove silence"))
        assertEquals("not a key", cs.translate("not a key"))
        assertTrue(Strings.fromXcstrings(json, "en").translate("Duplicate") == "Duplicate")
    }
}
