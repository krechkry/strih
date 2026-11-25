// Ported from Bombocut/Editor/EditorModel.swift (iOS ad3827a). Part 1: undo / redo, mutate + commit, split,
// clipHalves, delete, duplicate, move, trim. Same names and the same rules; Compose state instead of @Published.
package cz.krechler.bombocut.editor

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import cz.krechler.bombocut.model.AppleDate
import cz.krechler.bombocut.model.Clip
import cz.krechler.bombocut.model.MotionAnim
import cz.krechler.bombocut.model.Project
import cz.krechler.bombocut.model.ProjectStore
import cz.krechler.bombocut.model.followFootage
import java.util.UUID

class EditorModel(start: Project, private val store: ProjectStore?) {
    var project by mutableStateOf(start)
        private set
    var currentTime by mutableStateOf(0.0)
    var selectedClipID by mutableStateOf<UUID?>(null)
    /** A text / layer or a sound picked in its lane (picking one lets go of the others, like iOS). */
    var selectedOverlayID by mutableStateOf<UUID?>(null)
    var selectedAudioID by mutableStateOf<UUID?>(null)
    var canUndo by mutableStateOf(false)
        private set
    var canRedo by mutableStateOf(false)
        private set

    private val undoStack = ArrayDeque<Project>()
    private val redoStack = ArrayDeque<Project>()

    val duration: Double get() = project.duration
    val selectedIndex: Int? get() = selectedClipID?.let { id -> project.clips.indexOfFirst { it.id == id }.takeIf { it >= 0 } }

    // MARK: Undo

    /** One undo step: the change, then captions / overlays / sounds follow their footage, then commit. */
    fun mutate(change: (Project) -> Project) {
        val before = project
        pushUndo(before)
        project = change(before).followFootage(before)
        commit()
    }

    private fun pushUndo(p: Project) {
        undoStack.addLast(p)
        if (undoStack.size > 200) undoStack.removeFirst()
        redoStack.clear()
    }

    fun undo() {
        val p = undoStack.removeLastOrNull() ?: return
        redoStack.addLast(project)
        project = p
        commit()
    }

    fun redo() {
        val p = redoStack.removeLastOrNull() ?: return
        undoStack.addLast(project)
        project = p
        commit()
    }

    private fun commit() {
        project = project.normalizeOverlays().cleanStacks().copy(modified = AppleDate.now())
        store?.save(project)
        canUndo = undoStack.isNotEmpty()
        canRedo = redoStack.isNotEmpty()
        if (selectedClipID != null && project.clips.none { it.id == selectedClipID }) selectedClipID = null
        currentTime = minOf(currentTime, duration)
    }

    // MARK: Clips

    fun split() {
        val t = currentTime
        val hit = project.clipIndex(t) ?: return
        val i = hit.first
        val c = project.clips[i]
        val src = c.retime.source(t - hit.second)
        val (a, b) = clipHalves(c, src) ?: return
        mutate { p ->
            p.copy(clips = p.clips.toMutableList().also { it[i] = a; it.add(i + 1, b) }).joinStack(b.id, c.id)
        }
        selectedClipID = b.id
    }

    fun deleteSelected() {
        val i = selectedIndex ?: return
        mutate { p -> p.copy(clips = p.clips.toMutableList().also { it.removeAt(i) }) }
        selectedClipID = null
        val cut = if (i < project.clips.size) project.clipStarts[i] else duration
        currentTime = cut.coerceIn(0.0, duration)
    }

    fun duplicateSelected() {
        val i = selectedIndex ?: return
        val from = project.clips[i]
        val copy = from.copy(id = UUID.randomUUID(), cut = null)
        mutate { p -> p.copy(clips = p.clips.toMutableList().also { it.add(i + 1, copy) }).joinStack(copy.id, from.id) }
        selectedClipID = copy.id
    }

    /** Hold-and-drag reorder finished: clip moves from index `from` to `to` (captions go with it). */
    fun moveClip(from: Int, to: Int) {
        if (from == to || from !in project.clips.indices || to !in project.clips.indices) return
        val id = project.clips[from].id
        mutate { p ->
            val list = p.clips.toMutableList()
            val c = list.removeAt(from)
            list.add(to, c)
            p.copy(clips = list).leaveStackIfMovedAway(c.id)
        }
        selectedClipID = id
        project.clips.indexOfFirst { it.id == id }.takeIf { it >= 0 }?.let { currentTime = project.clipStarts[it] }
    }

    // MARK: Trim (ripple, like DaVinci's trim mode: clips stay glued)

    private var trimOriginal: Clip? = null
    private var trimSnapshot: Project? = null

    fun trimBegan(id: UUID) {
        val c = project.clips.firstOrNull { it.id == id } ?: return
        trimSnapshot = project
        trimOriginal = c
        selectedClipID = id
    }

    /** delta = seconds of timeline movement of the dragged edge since the drag began. */
    fun trimChanged(id: UUID, leading: Boolean, delta: Double) {
        val o = trimOriginal ?: return
        val i = project.clips.indexOfFirst { it.id == id }.takeIf { it >= 0 } ?: return
        var c = project.clips[i]
        val rt = o.retime
        c = if (leading) {
            val target = o.inPoint + delta * rt.speed(0.0)
            c.copy(inPoint = target.coerceIn(0.0, o.outPoint - 0.1))
        } else {
            val target = o.outPoint + delta * rt.speed(rt.outDuration)
            c.copy(outPoint = target.coerceIn(o.inPoint + 0.1, o.sourceDuration))
        }
        if (o.hasCurve && o.sticksCurve) c = c.copy(speedCurve = c.stuckCurve(o))
        project = project.copy(clips = project.clips.toMutableList().also { it[i] = c })
    }

    fun trimEnded() {
        val s = trimSnapshot
        if (s != null && s != project) {
            pushUndo(s)
            project = project.followFootage(s)
            commit()
        }
        trimSnapshot = null
        trimOriginal = null
    }

    // MARK: Live lane drags (one undo step when the finger lifts)

    private var laneSnapshot: Project? = null

    fun laneDragBegan() { if (laneSnapshot == null) laneSnapshot = project }

    /** `change` gets the project as it was when the drag began (so a drag never adds up rounding). */
    fun laneDragChanged(change: (Project) -> Project) {
        val s = laneSnapshot ?: return
        project = change(s)
    }

    fun laneDragEnded() {
        val s = laneSnapshot ?: return
        laneSnapshot = null
        if (s != project) { pushUndo(s); commit() }
    }

    companion object {
        /** A clip cut in two at source time `src` (nil when either piece would be too short). */
        fun clipHalves(c: Clip, src: Double): Pair<Clip, Clip>? {
            if (src - c.inPoint <= 0.05 || c.outPoint - src <= 0.05) return null
            var a = c.copy(outPoint = src)
            var b = c.copy(id = UUID.randomUUID(), inPoint = src)
            // the cut in stays with the first piece; the clip's in / out animations stay at its ends
            b = b.copy(cut = null, anim = b.anim.copy(inAnim = MotionAnim.none), fadeIn = 0.0)
            a = a.copy(anim = a.anim.copy(outAnim = MotionAnim.none), fadeOut = 0.0)
            if (c.hasCurve) {
                val u = (src - c.inPoint) / (c.outPoint - c.inPoint)
                a = a.copy(speedCurve = c.subCurve(0.0, u))
                b = b.copy(speedCurve = c.subCurve(u, 1.0))
            }
            return a to b
        }
    }
}

// MARK: Speed, volume, fades (EditorModel.swift)

fun EditorModel.setSpeed(v0: Double) {
    val i = selectedIndex ?: return
    val v = v0.coerceIn(0.1, 100.0)
    val c = project.clips[i]
    if (!c.hasCurve && kotlin.math.abs(c.speed - v) <= 1e-6) return
    mutate { p -> p.copy(clips = p.clips.toMutableList().also { it[i] = it[i].copy(speed = v, speedCurve = null) }) }
}

fun EditorModel.setCurve(pts: List<cz.krechler.bombocut.model.SpeedPoint>) {
    val i = selectedIndex ?: return
    if (project.clips[i].speedCurve == pts) return
    mutate { p -> p.copy(clips = p.clips.toMutableList().also { it[i] = it[i].copy(speedCurve = pts) }) }
}

/** Also remembered for new clips (Settings > Defaults). */
fun EditorModel.setPitch(on: Boolean) {
    cz.krechler.bombocut.model.Defaults.keepPitch = on
    val i = selectedIndex ?: return
    if (project.clips[i].pitchCorrect == on) return
    mutate { p -> p.copy(clips = p.clips.toMutableList().also { it[i] = it[i].copy(pitchCorrect = on) }) }
}

fun EditorModel.setCurveSticks(on: Boolean) {
    cz.krechler.bombocut.model.Defaults.stickSpeedCurve = on
    val i = selectedIndex ?: return
    val c = project.clips[i]
    if (c.sticksCurve == on && c.curveSticks != null) return
    mutate { p -> p.copy(clips = p.clips.toMutableList().also { it[i] = it[i].copy(curveSticks = on) }) }
}

fun EditorModel.setVolume(v: Double) {
    val i = selectedIndex ?: return
    if (project.clips[i].volume == v) return
    mutate { p -> p.copy(clips = p.clips.toMutableList().also { it[i] = it[i].copy(volume = v.coerceIn(0.0, 1.0)) }) }
}

fun EditorModel.setClipFade(fadeIn: Double? = null, fadeOut: Double? = null) {
    val i = selectedIndex ?: return
    val c = project.clips[i]
    val n = c.copy(fadeIn = fadeIn ?: c.fadeIn, fadeOut = fadeOut ?: c.fadeOut)
    if (n == c) return
    mutate { p -> p.copy(clips = p.clips.toMutableList().also { it[i] = n }) }
}
