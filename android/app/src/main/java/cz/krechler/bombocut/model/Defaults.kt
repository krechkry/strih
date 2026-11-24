// Ported from Bombocut/Model/Defaults.swift (iOS ad3827a). Same keys as iOS UserDefaults.
package cz.krechler.bombocut.model

/** Where settings live (SharedPreferences in the app, a map in unit tests). */
interface SettingsStore {
    fun double(key: String): Double?
    fun bool(key: String): Boolean?
    fun string(key: String): String?
    fun set(key: String, value: Any?)
}

class MemorySettings : SettingsStore {
    private val m = HashMap<String, Any?>()
    override fun double(key: String) = m[key] as? Double
    override fun bool(key: String) = m[key] as? Boolean
    override fun string(key: String) = m[key] as? String
    override fun set(key: String, value: Any?) { m[key] = value }
}

/** Settings > Defaults: how new things start out. */
object Defaults {
    var store: SettingsStore = MemorySettings()

    var transitionLength: Double
        get() = store.double("defTransition") ?: 0.5
        set(v) = store.set("defTransition", v)
    var stillLength: Double
        get() = store.double("defStill") ?: 2.0   // StillVideo.defaultDuration
        set(v) = store.set("defStill", v)
    var layerLength: Double
        get() = store.double("defLayer") ?: 3.0
        set(v) = store.set("defLayer", v)
    var keepPitch: Boolean
        get() = store.bool("defKeepPitch") ?: true
        set(v) = store.set("defKeepPitch", v)
    var stickSpeedCurve: Boolean
        get() = store.bool("defStickCurve") ?: false
        set(v) = store.set("defStickCurve", v)
    var fillNewClips: Boolean
        get() = store.bool("defFill") ?: false
        set(v) = store.set("defFill", v)
}
