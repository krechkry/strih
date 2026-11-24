package cz.krechler.bombocut.model

import kotlinx.serialization.KSerializer
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import java.util.UUID

/** UUIDs as Swift writes them: upper case strings. */
object UUIDSerializer : KSerializer<UUID> {
    override val descriptor = PrimitiveSerialDescriptor("UUID", PrimitiveKind.STRING)
    override fun deserialize(decoder: Decoder): UUID = UUID.fromString(decoder.decodeString())
    override fun serialize(encoder: Encoder, value: UUID) = encoder.encodeString(value.toString().uppercase())
}

/** Dates as Swift's JSONEncoder writes them by default: seconds since 1 Jan 2001 (a Double). */
object AppleDate {
    const val epochOffset = 978_307_200.0   // seconds from 1970 to 2001
    fun fromSwift(seconds: Double): Double = seconds + epochOffset   // to Unix seconds
    fun toSwift(unixSeconds: Double): Double = unixSeconds - epochOffset
    fun now(): Double = toSwift(System.currentTimeMillis() / 1000.0)
}
