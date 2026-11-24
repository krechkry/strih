// Ported from Bombocut/Model/Pin.swift (iOS ad3827a). Part 1: the stored data; PinPath math with tracking.
package cz.krechler.bombocut.model

import kotlinx.serialization.Serializable
import java.util.UUID

@Serializable
data class PinSample(val t: Double, val x: Double, val y: Double, val a: Double, val z: Double)

/** Track: an overlay stuck to a point of the footage under it. */
@Serializable
data class OverlayPin(
    val media: String? = null,
    @Serializable(with = UUIDSerializer::class) val clip: UUID? = null,
    val ref: Double,
    val samples: List<PinSample>,
    val position: Boolean = true,
    val rotation: Boolean = true,
    val scale: Boolean = true,
    val box: List<Double>? = null,
) {
    val followsAnything: Boolean get() = position || rotation || scale
}
