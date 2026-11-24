// Ported from Bombocut/Model/Overlay.swift (iOS ad3827a).
@file:Suppress("EnumEntryName")
package cz.krechler.bombocut.model

import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonEncoder
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.double
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.util.UUID
import kotlin.math.abs

/** How an overlay mixes with what is under it. */
@Serializable
enum class BlendMode {
    normal, screen, multiply, overlay, softLight, add, lighten, darken, difference;
    val title: String
        get() = when (this) {
            normal -> "Normal"; screen -> "Screen"; multiply -> "Multiply"; overlay -> "Overlay"; softLight -> "Soft light"
            add -> "Add"; lighten -> "Lighten"; darken -> "Darken"; difference -> "Difference"
        }
}

/** A keyframe of an overlay, `t` seconds after the overlay starts. */
@Serializable
data class OverlayKey(
    @Serializable(with = UUIDSerializer::class) val id: UUID = UUID.randomUUID(),
    val t: Double,
    val transform: ClipTransform,
    val opacity: Double,
    val ease: Ease = Ease.smooth,
    val easeDir: EaseDir? = null,
)

/** What an overlay shows. Stored the way Swift stores an enum with values: `{"text": {"_0": "Hi"}}`. */
@Serializable(with = OverlayKindSerializer::class)
sealed class OverlayKind {
    data class Text(val text: String) : OverlayKind()
    data class Image(val file: String) : OverlayKind()
    data class Video(val file: String, val sourceDuration: Double, val inPoint: Double) : OverlayKind()
    /** Shows nothing itself: its Adjust and filter change everything drawn under it. */
    data object Adjustment : OverlayKind()

    val isVideo: Boolean get() = this is Video
    val isAdjustment: Boolean get() = this is Adjustment
    val mediaFile: String? get() = when (this) { is Image -> file; is Video -> file; else -> null }
}

object OverlayKindSerializer : KSerializer<OverlayKind> {
    override val descriptor: SerialDescriptor = JsonElement.serializer().descriptor

    override fun deserialize(decoder: Decoder): OverlayKind {
        val o = (decoder as JsonDecoder).decodeJsonElement().jsonObject
        o["text"]?.let { return OverlayKind.Text(it.jsonObject["_0"]!!.jsonPrimitive.content) }
        o["image"]?.let { return OverlayKind.Image(it.jsonObject["file"]!!.jsonPrimitive.content) }
        o["video"]?.let {
            val v = it.jsonObject
            return OverlayKind.Video(v["file"]!!.jsonPrimitive.content, v["sourceDuration"]!!.jsonPrimitive.double,
                                     v["inPoint"]!!.jsonPrimitive.double)
        }
        if (o.containsKey("adjustment")) return OverlayKind.Adjustment
        throw kotlinx.serialization.SerializationException("Unknown overlay kind ${o.keys}")
    }

    override fun serialize(encoder: Encoder, value: OverlayKind) {
        val e = when (value) {
            is OverlayKind.Text -> JsonObject(mapOf("text" to JsonObject(mapOf("_0" to JsonPrimitive(value.text)))))
            is OverlayKind.Image -> JsonObject(mapOf("image" to JsonObject(mapOf("file" to JsonPrimitive(value.file)))))
            is OverlayKind.Video -> JsonObject(mapOf("video" to JsonObject(mapOf(
                "file" to JsonPrimitive(value.file), "sourceDuration" to JsonPrimitive(value.sourceDuration),
                "inPoint" to JsonPrimitive(value.inPoint)))))
            OverlayKind.Adjustment -> JsonObject(mapOf("adjustment" to JsonObject(emptyMap())))
        }
        (encoder as JsonEncoder).encodeJsonElement(e)
    }
}

/** A layer above the clips: text, a picture, a video or an adjustment layer. */
@Serializable
data class Overlay(
    @Serializable(with = UUIDSerializer::class) val id: UUID = UUID.randomUUID(),
    val kind: OverlayKind,
    val start: Double = 0.0,
    val duration: Double = 3.0,
    val transform: ClipTransform = ClipTransform(),
    val opacity: Double = 1.0,
    val blend: BlendMode = BlendMode.normal,
    val style: CaptionStyle = defaultTextStyle,
    val aspect: Double? = null,
    val behindSubject: Boolean = false,
    val keys: List<OverlayKey> = emptyList(),
    val volume: Double = 1.0,
    val anim: AnimPair = AnimPair(),
    val track: Int? = null,
    val effects: Effects = Effects(),
    val speed: Double = 1.0,
    val mask: SubjectMask? = null,
    val stabilization: Stabilization? = null,
    val tracking: Tracking? = null,
    val crop: CropRect? = null,
    val filter: LookFilter? = null,
    val key: ChromaKey? = null,
    val autoZoom: AutoZoom? = null,
    val asset: String? = null,
    val speedCurve: List<SpeedPoint>? = null,
    val curveIn: Double? = null,
    val curveSpan: Double? = null,
    val pin: OverlayPin? = null,
) {
    val end: Double get() = start + duration
    val isText: Boolean get() = kind is OverlayKind.Text
    val isAdjustment: Boolean get() = kind.isAdjustment
    val isMedia: Boolean get() = !isText && !isAdjustment
    val takesFilter: Boolean get() = !isText

    val title: String
        get() = when (val k = kind) {
            is OverlayKind.Text -> k.text.ifEmpty { "Text" }
            is OverlayKind.Image -> "Picture"
            is OverlayKind.Video -> "Video"
            OverlayKind.Adjustment -> "Adjustment"
        }

    val isCurved: Boolean
        get() = kind.isVideo && (speedCurve?.size ?: 0) >= 2 && curveIn != null && (curveSpan ?: 0.0) > 0

    val curveRetime: Retime?
        get() = if (!isCurved) null else Retime(curveIn!!, curveSpan!!, speedCurve)

    fun sourceTime(now: Double): Double {
        val v = kind as? OverlayKind.Video ?: return 0.0
        curveRetime?.let { rt -> return rt.source(rt.local(v.inPoint) + maxOf(0.0, now - start)) }
        return v.inPoint + maxOf(0.0, now - start) * speed
    }

    val maxDuration: Double?
        get() {
            val v = kind as? OverlayKind.Video ?: return null
            curveRetime?.let { rt -> return maxOf(0.2, rt.outDuration - rt.local(v.inPoint)) }
            return maxOf(0.2, (v.sourceDuration - v.inPoint) / maxOf(speed, 0.05))
        }

    /** Placement and opacity at timeline time `now`. */
    fun pose(now: Double): Pair<ClipTransform, Double> {
        val first = keys.firstOrNull() ?: return transform to opacity
        val s = now - start
        if (keys.size == 1 || s <= first.t) return first.transform to first.opacity
        val last = keys[keys.size - 1]
        if (s >= last.t) return last.transform to last.opacity
        var i = 0
        while (i < keys.size - 2 && s > keys[i + 1].t) i += 1
        val a = keys[i]; val b = keys[i + 1]
        var f = ((s - a.t) / maxOf(b.t - a.t, 1e-9)).coerceIn(0.0, 1.0)
        f = a.ease.apply(f, a.easeDir ?: EaseDir.both)
        val l = Look.lerp(Look(a.transform, a.opacity), Look(b.transform, b.opacity), f)
        return l.transform to l.opacity
    }

    fun keyIndex(now: Double): Int? = keys.indexOfFirst { abs(it.t - (now - start)) < 0.025 }.takeIf { it >= 0 }

    /** Changes placement / opacity at `now`: the fixed values, the keyframe there, or a new keyframe. */
    fun changePose(now: Double, change: (ClipTransform, Double) -> Pair<ClipTransform, Double>): Overlay {
        if (keys.isEmpty()) { val (t, o) = change(transform, opacity); return copy(transform = t, opacity = o) }
        keyIndex(now)?.let { k ->
            val (t, o) = change(keys[k].transform, keys[k].opacity)
            return copy(keys = keys.toMutableList().also { it[k] = it[k].copy(transform = t, opacity = o) })
        }
        val (pt, po) = pose(now)
        val (t, o) = change(pt, po)
        return copy(keys = (keys + OverlayKey(t = (now - start).coerceIn(0.0, duration), transform = t, opacity = o)).sortedBy { it.t })
    }

    /** Size on the canvas before its transform for pictures and videos: fitted inside 70 % of the canvas. */
    fun baseFraction(canvasAspect: Double): Pair<Double, Double> {
        val a = maxOf(aspect ?: 1.0, 0.0001)
        val r = a / maxOf(canvasAspect, 0.0001)
        return minOf(1.0, r) * 0.7 to minOf(1.0, 1 / r) * 0.7
    }

    companion object {
        val defaultTextStyle = CaptionStyle(size = 0.075, anim = CaptionAnim.none, shadow = false, strokeWidth = 0.0,
                                            strokeOutside = true, box = false, lines = 3, punctuation = true)
    }
}
