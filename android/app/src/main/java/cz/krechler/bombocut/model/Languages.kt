// Ported from Bombocut/Model/Languages.swift (iOS a28b16c): CaptionLanguage, the 25 languages Parakeet hears.
package cz.krechler.bombocut.model

object CaptionLanguage {
    data class Item(val code: String, val name: String, val flag: String)

    val all = listOf(
        Item("bg", "Български", "🇧🇬"), Item("cs", "Čeština", "🇨🇿"), Item("da", "Dansk", "🇩🇰"),
        Item("de", "Deutsch", "🇩🇪"), Item("el", "Ελληνικά", "🇬🇷"), Item("en", "English", "🇬🇧"),
        Item("es", "Español", "🇪🇸"), Item("et", "Eesti", "🇪🇪"), Item("fi", "Suomi", "🇫🇮"),
        Item("fr", "Français", "🇫🇷"), Item("hr", "Hrvatski", "🇭🇷"), Item("hu", "Magyar", "🇭🇺"),
        Item("it", "Italiano", "🇮🇹"), Item("lt", "Lietuvių", "🇱🇹"), Item("lv", "Latviešu", "🇱🇻"),
        Item("mt", "Malti", "🇲🇹"), Item("nl", "Nederlands", "🇳🇱"), Item("pl", "Polski", "🇵🇱"),
        Item("pt", "Português", "🇵🇹"), Item("ro", "Română", "🇷🇴"), Item("ru", "Русский", "🇷🇺"),
        Item("sk", "Slovenčina", "🇸🇰"), Item("sl", "Slovenščina", "🇸🇮"), Item("sv", "Svenska", "🇸🇪"),
        Item("uk", "Українська", "🇺🇦"),
    )

    fun item(code: String) = all.firstOrNull { it.code == code }
    fun name(code: String) = item(code)?.name ?: code
}
