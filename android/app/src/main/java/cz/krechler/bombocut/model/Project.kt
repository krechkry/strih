// Ported from Bombocut/Model/Models.swift (Project), Overlay.swift (rows) and Stack.swift (Project extension),
// iOS ad3827a. Immutable: every Swift `mutating func` returns the changed Project here.
package cz.krechler.bombocut.model

import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import java.util.UUID

/** A video left out of a light .bbc file, to fetch from iCloud Photos (iPhone only; kept and passed on). */
@Serializable
data class PhotosRef(val file: String, val cloud: String, val size: Long)

/** A cut's shape: seconds the clips overlap, the clip before plays on (tail), clip k starts early (head). */
data class CutShape(val shrink: Double, val tail: Double, val head: Double) {
    companion object { val none = CutShape(0.0, 0.0, 0.0) }
}

@Serializable(with = ProjectSerializer::class)
data class Project(
    val id: UUID = UUID.randomUUID(),
    val name: String,
    /** Seconds since 1 Jan 2001, like Swift's Date in JSON. */
    val created: Double = AppleDate.now(),
    val modified: Double = AppleDate.now(),
    val canvas: Canvas = Canvas(),
    val clips: List<Clip> = emptyList(),
    val captionTracks: List<Captions> = emptyList(),
    val activeCaption: Int = 0,
    val overlays: List<Overlay> = emptyList(),
    val audio: List<AudioItem> = emptyList(),
    val stacks: List<ClipStack> = emptyList(),
    val background: List<Double>? = null,
    val cloudPhotos: List<PhotosRef>? = null,
) {
    /** The caption track being edited. */
    val captions: Captions?
        get() = captionTracks.getOrNull(activeCaption) ?: captionTracks.firstOrNull()

    /** Setting nil removes the active track (Swift's `captions` setter). */
    fun withCaptions(v: Captions?): Project {
        if (v != null) {
            return if (activeCaption in captionTracks.indices) copy(captionTracks = captionTracks.toMutableList().also { it[activeCaption] = v })
            else copy(captionTracks = captionTracks + v, activeCaption = captionTracks.size)
        }
        if (activeCaption !in captionTracks.indices) return this
        val left = captionTracks.toMutableList().also { it.removeAt(activeCaption) }
        return copy(captionTracks = left, activeCaption = maxOf(0, minOf(activeCaption, left.size - 1)))
    }

    /** Length of the whole video: clips one after another, minus the overlaps of transitions. */
    val duration: Double
        get() {
            val d = clips.map { it.duration }
            if (d.isEmpty()) return 0.0
            val s = starts(clips, d)
            return s.last() + d.last()
        }

    fun overlap(k: Int): Double = cutShape(k).shrink

    fun cutShape(k: Int): CutShape = if (k <= 0 || k >= clips.size) CutShape.none else cutShape(clips[k].cut, clips[k - 1], clips[k])

    /** Timeline start time of each clip. */
    val clipStarts: List<Double> get() = starts(clips, clips.map { it.duration })

    /** Index of the clip under timeline time t and its start (inside a transition: the earlier until the middle). */
    fun clipIndex(t: Double): Pair<Int, Double>? {
        val d = clips.map { it.duration }
        if (d.isEmpty()) return null
        val st = starts(clips, d)
        for (i in clips.indices) {
            val s = if (i == 0) 0.0 else st[i] + (st[i - 1] + d[i - 1] - st[i]) / 2
            val e = if (i + 1 < clips.size) st[i + 1] + (st[i] + d[i] - st[i + 1]) / 2 else st[i] + d[i]
            if (t >= s && t < e) return i to st[i]
        }
        val last = clips.size - 1
        if (t >= st[last] + d[last] - 0.0001) return last to st[last]
        return null
    }

    /** Every imported file the project needs. */
    val mediaFiles: Set<String>
        get() = clips.flatMap { it.allMediaFiles }.toSet() + overlays.mapNotNull { it.kind.mediaFile } +
            audio.flatMap { listOf(it.file) + (it.reverse?.let { r -> listOf(r.file) } ?: emptyList()) }

    /** Earlier versions faded out and in through black: those become real transitions. */
    fun migrateCutTransitions(): Project {
        if (clips.size <= 1) return this
        val c = clips.toMutableList()
        for (k in 1 until c.size) {
            if (c[k].cut != null) continue
            val a = c[k - 1].anim; val b = c[k].anim
            if (a.outAnim == MotionAnim.none || a.outAnim != b.inAnim) continue
            c[k] = c[k].copy(cut = CutTransition(kind = b.inAnim, duration = maxOf(a.outDur, b.inDur)),
                             anim = c[k].anim.copy(inAnim = MotionAnim.none))
            c[k - 1] = c[k - 1].copy(anim = c[k - 1].anim.copy(outAnim = MotionAnim.none))
        }
        return copy(clips = c)
    }

    // MARK: Overlay rows (Overlay.swift)

    fun overlayRows(): List<List<Overlay>> {
        if (overlays.isEmpty()) return emptyList()
        val n = (overlays.mapNotNull { it.track }.maxOrNull() ?: 0) + 1
        val rows = List(n) { mutableListOf<Overlay>() }
        for (o in overlays) rows[(o.track ?: 0).coerceIn(0, n - 1)].add(o)
        return rows.filter { it.isNotEmpty() }.map { r -> r.sortedBy { it.start } }
    }

    /** Projects from before texts and pictures shared rows: picture rows go below the text rows. */
    fun mergeOverlayLanes(): Project {
        fun overlaps(a: Overlay, b: Overlay) = a.start < b.end - 0.001 && b.start < a.end - 0.001
        val ov = overlays.toMutableList()
        var textRows = 0
        for (texts in listOf(true, false)) {
            val idx = ov.indices.filter { ov[it].isText == texts }
            if (idx.isEmpty()) continue
            if (idx.all { ov[it].track == null }) {
                val rows = mutableListOf<MutableList<Int>>()
                for (i in idx) {
                    val r = rows.indexOfFirst { row -> row.all { !overlaps(ov[it], ov[i]) } }
                    if (r >= 0) rows[r].add(i) else rows.add(mutableListOf(i))
                }
                for ((r, row) in rows.withIndex()) for (i in row) ov[i] = ov[i].copy(track = rows.size - 1 - r)
            }
            val used = idx.mapNotNull { ov[it].track }.toSet().sorted()
            for (i in idx) ov[i] = ov[i].copy(track = maxOf(0, used.indexOf(ov[i].track ?: 0)) + if (texts) 0 else textRows)
            if (texts) textRows = used.size
        }
        return copy(overlays = ov)
    }

    /** Every overlay gets a row, rows never hold two overlapping blocks, empty rows close up, drawing order. */
    fun normalizeOverlays(): Project {
        fun overlaps(a: Overlay, b: Overlay) = a.start < b.end - 0.001 && b.start < a.end - 0.001
        if (overlays.isEmpty()) return this
        val rank = HashMap<UUID, Double>()
        for (o in overlays) rank[o.id] = o.track?.toDouble() ?: -0.5
        var bump = 0.0
        for (t in rank.values.toSet().sorted()) {
            val kept = mutableListOf<Overlay>()
            for (o in overlays.filter { rank[it.id] == t }.sortedBy { it.start }) {
                if (kept.any { overlaps(it, o) }) { bump += 0.001; rank[o.id] = t - 0.5 + bump } else kept.add(o)
            }
        }
        val order = rank.values.toSet().sorted()
        val ranked = overlays.map { it.copy(track = maxOf(0, order.indexOf(rank[it.id] ?: 0.0))) }
        val sorted = ranked.withIndex().sortedWith(compareBy({ -(it.value.track ?: 0) }, { it.index })).map { it.value }
        return copy(overlays = sorted)
    }

    // MARK: Stacks (Stack.swift)

    fun stack(of: UUID): ClipStack? = stacks.firstOrNull { of in it.clipIDs }

    fun stackRange(s: ClipStack): IntRange? {
        val ix = s.clipIDs.mapNotNull { id -> clips.indexOfFirst { it.id == id }.takeIf { it >= 0 } }
        val a = ix.minOrNull() ?: return null
        return a..ix.max()
    }

    fun stackTime(s: ClipStack): Pair<Double, Double>? {
        val r = stackRange(s) ?: return null
        val st = clipStarts
        return st[r.first] to st[r.last] + clips[r.last].duration
    }

    fun cleanStacks(): Project {
        if (stacks.isEmpty()) return syncStackSpeeds()
        val index = HashMap<UUID, Int>()
        clips.forEachIndexed { k, c -> index[c.id] = k }
        val taken = HashSet<Int>()
        val kept = stacks.mapNotNull { s ->
            val ix = s.clipIDs.mapNotNull { index[it] }
            val a = ix.minOrNull() ?: return@mapNotNull null
            val run = (a..ix.max()).filter { it !in taken }
            if (run.isEmpty()) return@mapNotNull null
            taken.addAll(run)
            s.copy(clipIDs = run.map { clips[it].id })
        }
        return copy(stacks = kept).syncStackSpeeds()
    }

    fun joinStack(new: UUID, old: UUID): Project {
        val k = stacks.indexOfFirst { old in it.clipIDs }
        if (k < 0 || new in stacks[k].clipIDs) return this
        return copy(stacks = stacks.toMutableList().also { it[k] = it[k].copy(clipIDs = it[k].clipIDs + new) }).syncStackSpeeds()
    }

    fun leaveStackIfMovedAway(id: UUID): Project {
        val k = stacks.indexOfFirst { id in it.clipIDs }
        val at = clips.indexOfFirst { it.id == id }
        if (k < 0 || at < 0) return this
        val others = stacks[k].clipIDs.filter { it != id }.mapNotNull { o -> clips.indexOfFirst { it.id == o }.takeIf { it >= 0 } }
        val a = others.minOrNull() ?: return this
        val b = others.max()
        var p = this
        if (at < a - 1 || at > b + 1) p = copy(stacks = stacks.toMutableList().also { it[k] = it[k].copy(clipIDs = it[k].clipIDs.filter { c -> c != id }) })
        return p.syncStackSpeeds()
    }

    /** Each clip carries its Stack's speed and motion blur. */
    fun syncStackSpeeds(): Project {
        val outer = HashMap<UUID, Double>(); val blur = HashMap<UUID, Double>()
        for (s in stacks) {
            if (kotlin.math.abs(s.speed - 1) > 1e-6) for (id in s.clipIDs) outer[id] = s.speed
            if (s.blurAmount > 0.001) for (id in s.clipIDs) blur[id] = s.blurAmount
        }
        var changed = false
        val c = clips.map { cl ->
            val v = outer[cl.id] ?: 1.0
            val b = blur[cl.id] ?: 0.0
            if (cl.outerSpeed != v || cl.stackBlur != b) { changed = true; cl.copy(outerSpeed = v, stackBlur = b) } else cl
        }
        return if (changed) copy(clips = c) else this
    }

    fun stackLocal(s: ClipStack, t: Double): Double? = stackTime(s)?.let { t - it.first }

    companion object {
        /** Centered on the cut and over the handles; what they can't cover overlaps the clips (max 45 % of either). */
        fun cutShape(cut: CutTransition?, a: Clip, b: Clip): CutShape {
            if (cut == null || cut.kind == MotionAnim.none) return CutShape.none
            val capA = a.duration * 0.45; val capB = b.duration * 0.45
            val d = maxOf(0.0, cut.duration)
            if (cut.handles != true) return CutShape(maxOf(0.0, minOf(d, capA, capB)), 0.0, 0.0)
            val hA = a.tailHandle; val hB = b.headHandle
            var tail = minOf(hA, d / 2)
            var head = minOf(hB, d / 2)
            tail = minOf(hA, d - head)
            head = minOf(hB, d - tail)
            tail = minOf(tail, capB)
            head = minOf(head, capA)
            val shrink = maxOf(0.0, minOf(d - tail - head, capB - tail, capA - head))
            return CutShape(shrink, tail, head)
        }

        private fun starts(clips: List<Clip>, d: List<Double>): List<Double> {
            val out = ArrayList<Double>(clips.size)
            for (k in clips.indices) {
                if (k == 0) { out.add(0.0); continue }
                out.add(out[k - 1] + d[k - 1] - cutShape(clips[k].cut, clips[k - 1], clips[k]).shrink)
            }
            return out
        }
    }
}

/** Project as stored, every key optional (Swift's init(from:) / encode(to:)). */
@Serializable
private data class ProjectStored(
    @Serializable(with = UUIDSerializer::class) val id: UUID? = null,
    val name: String? = null,
    val created: Double? = null,
    val modified: Double? = null,
    val canvas: Canvas? = null,
    val clips: List<Clip>? = null,
    val captions: Captions? = null,              // projects from before caption tracks
    val captionTracks: List<Captions>? = null,
    val activeCaption: Int? = null,
    val overlays: List<Overlay>? = null,
    val audio: List<AudioItem>? = null,
    val layerRows: Boolean? = null,
    val stacks: List<ClipStack>? = null,
    val background: List<Double>? = null,
    val cloudPhotos: List<PhotosRef>? = null,
)

object ProjectSerializer : KSerializer<Project> {
    private val stored = ProjectStored.serializer()
    override val descriptor: SerialDescriptor = stored.descriptor

    override fun deserialize(decoder: Decoder): Project {
        val s = decoder.decodeSerializableValue(stored)
        val tracks = s.captionTracks ?: s.captions?.let { listOf(it) } ?: emptyList()
        var p = Project(
            id = s.id ?: UUID.randomUUID(), name = s.name ?: "Project",
            created = s.created ?: AppleDate.now(), modified = s.modified ?: AppleDate.now(),
            canvas = s.canvas ?: Canvas(), clips = s.clips ?: emptyList(), captionTracks = tracks,
            activeCaption = (s.activeCaption ?: 0).coerceIn(0, maxOf(0, tracks.size - 1)),
            overlays = s.overlays ?: emptyList(), audio = s.audio ?: emptyList(),
        ).migrateCutTransitions()
        if (s.layerRows != true) p = p.mergeOverlayLanes()
        p = p.copy(stacks = (s.stacks ?: emptyList()).map { it.normalized() }).syncStackSpeeds()
        s.background?.takeIf { it.size == 3 }?.let { p = p.copy(background = it) }
        return p.copy(cloudPhotos = s.cloudPhotos)
    }

    override fun serialize(encoder: Encoder, value: Project) {
        val p = value
        encoder.encodeSerializableValue(stored, ProjectStored(
            id = p.id, name = p.name, created = p.created, modified = p.modified, canvas = p.canvas, clips = p.clips,
            captions = null, captionTracks = p.captionTracks, activeCaption = p.activeCaption, overlays = p.overlays,
            audio = p.audio, layerRows = true, stacks = p.stacks.ifEmpty { null }, background = p.background,
            cloudPhotos = p.cloudPhotos?.ifEmpty { null },
        ))
    }
}
