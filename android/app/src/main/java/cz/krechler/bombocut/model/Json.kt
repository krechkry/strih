package cz.krechler.bombocut.model

import kotlinx.serialization.json.Json

/** JSON the way the iOS app writes and reads it (see PORTING.md, "JSON contract"). */
val BomboJson = Json {
    encodeDefaults = true        // Swift writes every non-optional property
    explicitNulls = false        // ... and leaves out nil optionals
    ignoreUnknownKeys = true     // newer iOS keys never break an older Android
    coerceInputValues = true
}
