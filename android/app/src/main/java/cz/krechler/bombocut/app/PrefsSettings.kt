package cz.krechler.bombocut.app

import android.content.Context
import cz.krechler.bombocut.model.SettingsStore

/** Defaults and other settings in SharedPreferences, under the same keys iOS uses in UserDefaults. */
class PrefsSettings(context: Context) : SettingsStore {
    private val p = context.getSharedPreferences("bombocut", Context.MODE_PRIVATE)
    override fun double(key: String): Double? = if (p.contains(key)) runCatching { Double.fromBits(p.getLong(key, 0)) }.getOrNull() else null
    override fun bool(key: String): Boolean? = if (p.contains(key)) runCatching { p.getBoolean(key, false) }.getOrNull() else null
    override fun string(key: String): String? = runCatching { p.getString(key, null) }.getOrNull()
    override fun set(key: String, value: Any?) {
        val e = p.edit()
        when (value) {
            null -> e.remove(key)
            is Double -> e.putLong(key, value.toRawBits())
            is Boolean -> e.putBoolean(key, value)
            is String -> e.putString(key, value)
            is Int -> e.putInt(key, value)
        }
        e.apply()
    }
}
