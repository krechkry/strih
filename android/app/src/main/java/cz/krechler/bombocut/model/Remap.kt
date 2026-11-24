// Ported from Bombocut/Model/Captions.swift ("Captions follow their footage"), Overlay.swift (remapOverlays) and
// Audio.swift (remapAudio), iOS ad3827a: after clips are moved, trimmed, split, sped up or deleted, captions,
// overlays and sounds stay on the footage they belong to.
package cz.krechler.bombocut.model

import java.util.UUID
import kotlin.math.abs

/** What is on screen at timeline time t: which clip, and which moment of its source. */
data class Located(val index: Int, val id: UUID, val media: String, val src: Double)

fun Project.locate(t: Double): Located? {
    if (t < 0 || t > duration + 0.05) return null
    val hit = clipIndex(minOf(t, maxOf(0.0, duration - 1e-4))) ?: return null
    val c = clips[hit.first]
    return Located(hit.first, c.id, c.mediaFile, c.retime.source(t - hit.second))
}

/** Where that moment of footage now sits on the timeline (same clip, or a piece of it after a split). */
fun Project.timeline(id: UUID, media: String, src: Double, oldIndex: Int): Pair<Double, Int>? {
    val starts = clipStarts
    fun fits(c: Clip) = src >= c.inPoint - 0.02 && src <= c.outPoint + 0.02
    var pick: Int? = clips.indexOfFirst { it.id == id && fits(it) }.takeIf { it >= 0 }
    if (pick == null) pick = clips.indices.filter { clips[it].mediaFile == media && fits(clips[it]) }.minByOrNull { abs(it - oldIndex) }
    val i = pick ?: return null
    val c = clips[i]
    val s = src.coerceIn(c.inPoint, c.outPoint)
    return (starts[i] + c.retime.local(s)) to i
}

/** Fingerprint of everything that decides where clips sit in time. */
val Project.timingKey: List<Any>
    get() = clips.indices.flatMap { k -> val c = clips[k]; listOf(c.id, c.inPoint, c.outPoint, c.duration, overlap(k)) }

/** Words and cues follow their footage; speech whose footage is gone is dropped; manual edits stay. */
fun Captions.remapped(old: Project, new: Project): Captions {
    fun map(s: Double, e: Double): Pair<Double, Double>? {
        val mid = (s + e) / 2
        val a = old.locate(minOf(maxOf(s, 0.0), mid)) ?: return null
        val ns = new.timeline(a.id, a.media, a.src, a.index) ?: return null
        var ne = ns.first + (e - s)
        val b = old.locate(e - 1e-4)
        val t = if (b != null && b.id == a.id) new.timeline(a.id, a.media, b.src, a.index) else null
        if (t != null && t.second == ns.second) {
            ne = t.first
        } else {
            val c = new.clips[ns.second]
            ne = minOf(ne, new.clipStarts[ns.second] + c.duration)
        }
        return ns.first to maxOf(ne, ns.first + 0.04)
    }
    val newWords = words.mapNotNull { w -> map(w.start, w.end)?.let { CaptionWord(w.text, it.first, it.second) } }.sortedBy { it.start }
    val newCues = mutableListOf<CaptionCue>()
    for (q in cues) {
        val r = map(q.start, q.end) ?: continue
        val qw = q.words.mapNotNull { w -> map(w.start, w.end)?.let { CaptionWord(w.text, it.first, it.second) } }
        if (qw.isEmpty() && q.words.isNotEmpty()) continue
        newCues += q.copy(start = r.first, end = r.second, words = qw)
    }
    newCues.sortBy { it.start }
    for (i in 0 until newCues.size - 1) {
        if (newCues[i].end > newCues[i + 1].start - 0.02) {
            newCues[i] = newCues[i].copy(end = maxOf(newCues[i].start + 0.1, newCues[i + 1].start - 0.02))
        }
    }
    return copy(words = newWords, cues = newCues, cuts = cuts?.mapNotNull { t -> map(t - 0.01, t + 0.01)?.let { it.first + 0.01 } })
}

/** Same for overlays: each one follows the footage it starts on. */
fun remapOverlays(list: List<Overlay>, old: Project, new: Project): List<Overlay> = list.mapNotNull { o ->
    val a = old.locate(minOf(o.start + 0.001, maxOf(old.duration - 0.001, 0.0)))
    val n = a?.let { new.timeline(it.id, it.media, it.src, it.index) }
    if (n == null) (if (o.start < new.duration - 0.05) o else null) else o.copy(start = maxOf(0.0, n.first - 0.001))
}

/** Same for sounds. */
fun remapAudio(list: List<AudioItem>, old: Project, new: Project): List<AudioItem> = list.mapNotNull { a ->
    val at = old.locate(minOf(a.start + 0.001, maxOf(old.duration - 0.001, 0.0)))
    val n = at?.let { new.timeline(it.id, it.media, it.src, it.index) }
    if (n == null) (if (a.start < new.duration - 0.05) a else null) else a.copy(start = maxOf(0.0, n.first - 0.001))
}

/** EditorModel.followFootage: captions, overlays and sounds stick to the footage they belong to. */
fun Project.followFootage(before: Project): Project {
    if (before.timingKey == timingKey) return this
    var p = copy(captionTracks = captionTracks.map { it.remapped(before, this) })
    if (p.overlays.isNotEmpty()) p = p.copy(overlays = remapOverlays(p.overlays, before, this))
    if (p.audio.isNotEmpty()) p = p.copy(audio = remapAudio(p.audio, before, this))
    return p
}
