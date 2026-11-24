// Ported from Bombocut/Model/Languages.swift (AppLanguage), iOS base ad3827a.
// iOS reads its .lproj bundles; Android reads the same Localizable.xcstrings (copied into the assets by Gradle).
package cz.krechler.bombocut.app

import android.content.Context
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.util.Locale

/** English keys → the translation in one language. English is the key itself. */
class Strings(private val table: Map<String, String>) {
    fun translate(key: String): String = table[key] ?: key

    companion object {
        val english = Strings(emptyMap())

        /** The `code` translations of an .xcstrings file (plural / device variations fall back to the key). */
        fun fromXcstrings(json: String, code: String): Strings {
            if (code == "en") return english
            val root = Json.parseToJsonElement(json).jsonObject
            val all = root["strings"]?.jsonObject ?: return english
            val out = HashMap<String, String>(all.size)
            for ((key, v) in all) {
                val unit = (v as? JsonObject)?.get("localizations")?.jsonObject?.get(code)?.jsonObject
                    ?.get("stringUnit")?.jsonObject ?: continue
                unit["value"]?.jsonPrimitive?.content?.let { out[key] = it }
            }
            return Strings(out)
        }
    }
}

/** The language of the app's own buttons and texts (English or Czech). */
object AppLanguage {
    val options = listOf(Triple("en", "English", "🇬🇧"), Triple("cs", "Čeština", "🇨🇿"))
    const val KEY = "appLanguage"

    @Volatile var strings: Strings = Strings.english
        private set
    var current: String = "en"
        private set

    /** Picked in the app, or the phone's language when it is one we have. */
    fun load(context: Context) {
        val prefs = context.getSharedPreferences("bombocut", Context.MODE_PRIVATE)
        val picked = prefs.getString(KEY, null)?.takeIf { c -> options.any { it.first == c } }
        val phone = Locale.getDefault().language.let { if (it == "sk") "cs" else it }
        val code = picked ?: if (options.any { it.first == phone }) phone else "en"
        set(context, code, save = false)
    }

    fun set(context: Context, code: String, save: Boolean = true) {
        current = code
        strings = if (code == "en") Strings.english else {
            val json = context.assets.open("Localizable.xcstrings").bufferedReader().use { it.readText() }
            Strings.fromXcstrings(json, code)
        }
        if (save) context.getSharedPreferences("bombocut", Context.MODE_PRIVATE).edit().putString(KEY, code).apply()
    }
}
