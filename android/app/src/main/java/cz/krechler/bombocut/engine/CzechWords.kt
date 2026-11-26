// The Czech dictionary for SpellCheck.czech (iOS asks UITextChecker): 49,756 lowercase Czech words (assets/cs-words.txt.gz,
// 135 KB), from Hermit Dave's FrequencyWords (OpenSubtitles 2018, CC BY-SA 4.0): words seen at least 200 times, Czech
// letters only. The cut-off keeps out the Slovak that turns up in Czech subtitles ("viem", "môžeš" stay unknown).
package cz.krechler.bombocut.engine

import android.content.Context
import java.util.zip.GZIPInputStream

object CzechWords {
    @Volatile private var words: Set<String>? = null

    fun load(context: Context): Set<String> = words ?: synchronized(this) {
        words ?: context.assets.open("cs-words.txt.gz").use { GZIPInputStream(it).bufferedReader().readLines() }
            .filter { it.isNotEmpty() }.toHashSet().also { words = it }
    }
}
