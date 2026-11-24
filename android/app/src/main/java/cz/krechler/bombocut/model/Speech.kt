// Ported from Bombocut/Engine/SpeechCleanup.swift (iOS ad3827a): the settings a clip stores. The engine is a rework.
package cz.krechler.bombocut.model

import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder

@Serializable
enum class SpatialMixStyle {
    inFrame, studio, cinematic;
    val title: String get() = when (this) { inFrame -> "In frame"; studio -> "Studio"; cinematic -> "Cinematic" }
}

/** Speech settings of a clip: Audio Mix (iPhone spatial recordings only), noise removal, Restore voice. */
@Serializable(with = SpeechFXSerializer::class)
data class SpeechFX(
    val denoise: Double = 0.0,
    val restore: Double = 0.0,
    val mix: SpatialMixStyle? = null,
    val mixIntensity: Double = 0.6,
) {
    val isActive: Boolean get() = denoise > 0.001 || restore > 0.001 || mix != null
}

@Serializable
private data class SpeechFXStored(
    val denoise: Double? = null, val restore: Double? = null, val enhance: Boolean? = null,
    val mix: SpatialMixStyle? = null, val mixIntensity: Double? = null,
)

object SpeechFXSerializer : KSerializer<SpeechFX> {
    private val stored = SpeechFXStored.serializer()
    override val descriptor: SerialDescriptor = stored.descriptor
    override fun deserialize(decoder: Decoder): SpeechFX {
        val s = decoder.decodeSerializableValue(stored)
        // `enhance` is the old voice enhancer: read as Restore voice
        return SpeechFX(s.denoise ?: 0.0, s.restore ?: (if (s.enhance == true) 1.0 else 0.0), s.mix, s.mixIntensity ?: 0.6)
    }
    override fun serialize(encoder: Encoder, value: SpeechFX) = encoder.encodeSerializableValue(stored,
        SpeechFXStored(value.denoise, if (value.restore > 0.001) value.restore else null, null, value.mix, value.mixIntensity))
}
