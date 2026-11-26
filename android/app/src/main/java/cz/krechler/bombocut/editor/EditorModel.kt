// Ported from Bombocut/Editor/EditorModel.swift (iOS ad3827a). Part 1: undo / redo, mutate + commit, split,
// clipHalves, delete, duplicate, move, trim. Same names and the same rules; Compose state instead of @Published.
package cz.krechler.bombocut.editor

import kotlinx.coroutines.launch
import cz.krechler.bombocut.app.loc
import cz.krechler.bombocut.model.remapped
import cz.krechler.bombocut.model.replacingWords
import cz.krechler.bombocut.model.timingKey
import cz.krechler.bombocut.model.CaptionCutter
import cz.krechler.bombocut.model.Captions
import cz.krechler.bombocut.model.CaptionTemplate
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
    /** The free week is over and nothing is bought: the project only exports as it is, every edit is ignored. */
    var locked = false
    var currentTime by mutableStateOf(0.0)
    var selectedClipID by mutableStateOf<UUID?>(null)
    /** A text / layer or a sound picked in its lane (picking one lets go of the others, like iOS). */
    var selectedOverlayID by mutableStateOf<UUID?>(null)
    var selectedAudioID by mutableStateOf<UUID?>(null)
    /** A caption line picked in its lane (track, line). */
    var selectedCue by mutableStateOf<Pair<Int, UUID>?>(null)
    var canUndo by mutableStateOf(false)
        private set
    var canRedo by mutableStateOf(false)
        private set

    private val undoStack = ArrayDeque<Project>()
    private val redoStack = ArrayDeque<Project>()

    val duration: Double get() = project.duration
    val selectedIndex: Int? get() = selectedClipID?.let { id -> project.clips.indexOfFirst { it.id == id }.takeIf { it >= 0 } }

    // MARK: Captions (iOS EditorModel.startCaptions)

    /** A caption run: what it is doing, or what went wrong (shown in the Captions panel). */
    data class CaptionJob(val phase: cz.krechler.bombocut.engine.Transcriber.Phase, val error: String? = null)
    var captionJob by mutableStateOf<CaptionJob?>(null)
    /** Set when a run finished (the panel shows "Captions ready"). */
    var captionsReady by mutableStateOf(false)
    private var captionTask: kotlinx.coroutines.Job? = null
    private val scope = kotlinx.coroutines.MainScope()

    /**
     * Listens to the whole timeline and makes captions: the active track again (its style kept), or a new track
     * with a look no other track uses. The editor stays usable meanwhile: if the timeline changed, the captions
     * are moved onto it as it is now. One undo step.
     */
    fun startCaptions(context: android.content.Context, language: String, newTrack: Boolean, names: String = "") {
        if (locked || captionJob?.error == null && captionJob != null) return
        captionTask?.cancel()
        captionsReady = false
        cueNote = null
        // tapping Generate is the go-ahead: a paused download continues
        if (cz.krechler.bombocut.engine.SpeechDownload.state is cz.krechler.bombocut.engine.SpeechDownload.State.Paused)
            cz.krechler.bombocut.engine.SpeechDownload.start()
        captionJob = CaptionJob(cz.krechler.bombocut.engine.Transcriber.Phase.PreparingAudio)
        val snapshot = project
        val adding = newTrack || snapshot.captionTracks.isEmpty()
        val used = snapshot.captionTracks.mapNotNull { it.templateID }.toSet()
        val fresh = if (adding) CaptionTemplate.builtIns.firstOrNull { it.id !in used } ?: CaptionTemplate.builtIns[0] else null
        val old = if (adding) null else snapshot.captions
        val style = old?.style ?: fresh!!.style
        val tid = old?.templateID ?: fresh?.id
        captionTask = scope.launch {
            try {
                val words = cz.krechler.bombocut.engine.Transcriber.run(context, snapshot, language = language, names = names) { captionJob = CaptionJob(it) }
                if (words.isEmpty()) { captionJob = CaptionJob(cz.krechler.bombocut.engine.Transcriber.Phase.PreparingAudio, loc("No speech found.")); return@launch }
                var caps = Captions(language, words, CaptionCutter.cues(words, style), style, tid)
                // you kept editing meanwhile: the captions go onto the timeline as it is now
                if (snapshot.timingKey != project.timingKey) caps = caps.remapped(snapshot, project)
                val made = caps
                mutate { p ->
                    if (adding) p.copy(captionTracks = p.captionTracks + made, activeCaption = p.captionTracks.size)
                    else p.copy(captionTracks = p.captionTracks.toMutableList().also { it[p.activeCaption.coerceIn(0, it.size - 1)] = made })
                }
                captionJob = null
                captionsReady = true
            } catch (e: kotlinx.coroutines.CancellationException) {
                captionJob = null
            } catch (e: Exception) {
                android.util.Log.w("Bombocut", "captions failed", e)
                captionJob = CaptionJob(cz.krechler.bombocut.engine.Transcriber.Phase.PreparingAudio,
                    e.message?.takeIf { it.isNotBlank() } ?: loc("Download failed"))
            }
        }
    }

    /** Stops the run; while it was still downloading the model, the download pauses too (no data used behind your back). */
    fun cancelCaptions() {
        if (captionJob?.phase is cz.krechler.bombocut.engine.Transcriber.Phase.Downloading) cz.krechler.bombocut.engine.SpeechDownload.pause()
        captionTask?.cancel(); captionTask = null; captionJob = null
    }

    /** The line being heard again (its Regenerate button spins). */
    var regeneratingCue by mutableStateOf<UUID?>(null)
        private set
    /** What went wrong for a line heard again (shown under it until the next try). */
    data class CueNote(val id: UUID, val text: String)
    var cueNote by mutableStateOf<CueNote?>(null)

    /**
     * iOS regenerateCue: listens to one caption line again (a little before and after it, for context) and puts what
     * it heard into that line only. One undo step. Needs the model on the phone (no download from here).
     */
    fun regenerateCue(context: android.content.Context, track: Int, id: UUID) {
        if (locked || regeneratingCue != null || captionJob != null && captionJob?.error == null) return
        val caps = project.captionTracks.getOrNull(track) ?: return
        val cue = caps.cues.firstOrNull { it.id == id } ?: return
        if (!cz.krechler.bombocut.engine.SpeechModel.isReady) { cueNote = CueNote(id, loc("The speech model isn't downloaded yet.")); return }
        regeneratingCue = id
        cueNote = null
        val snapshot = project
        val lo = maxOf(0.0, cue.start - 0.6)
        val hi = minOf(maxOf(snapshot.duration, cue.end), cue.end + 0.6)
        scope.launch {
            try {
                // the typed names (Captions panel) and the track's language, like a whole run
                val names = cz.krechler.bombocut.app.PrefsSettings(context).string("captionNames") ?: ""
                val heard = cz.krechler.bombocut.engine.Transcriber.run(context, snapshot, lo..hi, language = caps.language, names = names) {}
                // the timeline moved meanwhile: the times would be off, leave the line alone
                if (project.timingKey != snapshot.timingKey) return@launch
                val now = project.captionTracks.getOrNull(track) ?: return@launch
                val fixed = now.replacingWords(id, heard)
                if (fixed == null) { cueNote = CueNote(id, loc("No speech found.")); return@launch }
                mutate { p -> p.copy(captionTracks = p.captionTracks.toMutableList().also { if (track < it.size) it[track] = fixed }) }
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                android.util.Log.w("Bombocut", "line again failed", e)
                cueNote = CueNote(id, e.message?.takeIf { it.isNotBlank() } ?: loc("No speech found."))
            } finally {
                regeneratingCue = null
            }
        }
    }

    // MARK: Undo

    /** One undo step: the change, then captions / overlays / sounds follow their footage, then commit. */
    fun mutate(change: (Project) -> Project) {
        if (locked) return
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
    fun trimChanged(id: UUID, leading: Boolean, delta0: Double, reach: Double = 0.0) {
        if (locked) return
        val o = trimOriginal ?: return
        val i = project.clips.indexOfFirst { it.id == id }.takeIf { it >= 0 } ?: return
        // the end of a clip snaps to the playhead, other clips' and blocks' edges and beats (iOS does too)
        var delta = delta0
        val snap = trimSnapshot
        if (!leading && snap != null && reach > 0) {
            val k = snap.clips.indexOfFirst { it.id == id }
            if (k >= 0) {
                val edge = snap.clipStarts[k] + o.duration
                delta = snapped(edge + delta0, reach, id, snap) - edge
            }
        }
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
        if (locked) return
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
