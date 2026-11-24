// Ported from Bombocut/Editor/SpeedSheet.swift (iOS ad3827a): Constant (0.1x to 100x on the bent scale, ticks
// snap) and Curve (the same graph scale, drag points, tap the line to add, delete, reset, playhead snap).
// Not yet: the panel's own undo / redo, Smooth slow motion, the speed label beside the finger, Apply to.
package cz.krechler.bombocut.editor

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import cz.krechler.bombocut.app.Fmt
import cz.krechler.bombocut.app.Theme
import cz.krechler.bombocut.app.loc
import cz.krechler.bombocut.model.SpeedCurve
import cz.krechler.bombocut.model.SpeedPoint
import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.log10
import kotlin.math.pow

object SpeedScale {
    private const val below = 1.0 / 3
    private const val bend = 0.5
    val ticks = listOf(0.1, 0.25, 0.5, 1.0, 2.0, 4.0, 10.0, 25.0, 100.0)

    /** Slider position 0...1: 0.1x to 1x on the first third, 1x to 100x on the rest (below 1x stretched). */
    fun position(v0: Double): Double {
        val v = v0.coerceIn(0.1, 100.0)
        if (v >= 1) return below + (1 - below) * log10(v) / 2
        return below * (1 - (-log10(v)).pow(bend))
    }

    fun speed(pos: Double): Double {
        val p = pos.coerceIn(0.0, 1.0)
        if (p >= below) return 10.0.pow((p - below) / (1 - below) * 2)
        return 10.0.pow(-(1 - p / below).pow(1 / bend))
    }

    private val logTop = log10(SpeedCurve.maxV)
    private val logBottom = log10(SpeedCurve.minV)
    private const val graphBend = 0.53
    private val oneAt get() = logTop / (logTop - logBottom)

    /** Graph height 0 (top, 15x) ... 1 (bottom, 0.05x), slow motion stretched. */
    fun graphY(v: Double): Double {
        val l = log10(maxOf(v, 1e-6))
        if (l >= 0) return (logTop - l) / (logTop - logBottom)
        val f = minOf(-l / -logBottom, 1.0).pow(graphBend)
        return oneAt + f * (1 - oneAt)
    }

    fun graphValue(y0: Double): Double {
        val y = y0.coerceIn(0.0, 1.0)
        val l = if (y <= oneAt) logTop - y * (logTop - logBottom) else -((y - oneAt) / (1 - oneAt)).pow(1 / graphBend) * -logBottom
        return 10.0.pow(l).coerceIn(SpeedCurve.minV, SpeedCurve.maxV)
    }
}

@Composable
fun SpeedSheet(model: EditorModel, scrub: (Double) -> Unit) {
    val i = model.selectedIndex ?: return
    val clip = model.project.clips[i]
    var tab by remember(clip.id) { mutableStateOf(if (clip.hasCurve) 1 else 0) }
    var speed by remember(clip.id) { mutableStateOf(clip.speed) }
    var points by remember(clip.id) { mutableStateOf(clip.speedCurve ?: SpeedCurve.flat()) }
    var selected by remember(clip.id) { mutableStateOf<Int?>(null) }
    val originalDuration = clip.outPoint - clip.inPoint

    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        listOf("Constant", "Curve").forEachIndexed { k, title ->
            TextButton({
                if (tab != k) {
                    tab = k
                    if (k == 0) model.setSpeed(speed) else {
                        if (!clip.hasCurve) points = SpeedCurve.flat(speed)
                        model.setCurve(points)
                    }
                }
            }, Modifier.background(if (tab == k) Theme.accent else Theme.panel2, RoundedCornerShape(50)).height(36.dp)) {
                Text(loc(title), color = if (tab == k) Color.Black else Color.White, fontWeight = FontWeight.Bold)
            }
        }
    }

    fun durationLine(newDuration: Double) = Fmt.duration(originalDuration) + " → " + Fmt.duration(newDuration)

    if (tab == 0) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Bottom) {
            Text(Fmt.speed(speed), color = Color.White, fontSize = 44.sp, fontWeight = FontWeight.Black)
            Spacer(Modifier.weight(1f))
            Text(durationLine(originalDuration / maxOf(speed, 0.01)), color = Theme.muted, fontWeight = FontWeight.SemiBold)
        }
        BSlider(SpeedScale.position(speed), 0.0..1.0, change = { v ->
            var s = SpeedScale.speed(v)
            for (t in SpeedScale.ticks) if (abs(SpeedScale.position(t) - v) < 0.0125) s = t
            speed = if (s >= 10) Math.round(s).toDouble() else Math.round(s * 100) / 100.0
        }, done = { model.setSpeed(speed) })
        BoxWithConstraints(Modifier.fillMaxWidth().height(16.dp)) {
            for (t in listOf(0.1, 0.5, 1.0, 2.0, 10.0, 100.0)) {
                Text(Fmt.speed(t), color = if (abs(speed - t) < 0.001) Theme.accent else Theme.muted, fontSize = 11.sp,
                     fontWeight = FontWeight.Bold,
                     modifier = Modifier.padding(start = (14.dp + (maxWidth - 28.dp) * SpeedScale.position(t).toFloat() - 10.dp).coerceAtLeast(0.dp)))
            }
        }
    } else {
        val preview = clip.copy(speedCurve = points).duration
        Row(Modifier.fillMaxWidth()) {
            Text(loc("Tap the line to add · slide to scrub"), color = Theme.muted, fontSize = 13.sp, fontWeight = FontWeight.SemiBold,
                 modifier = Modifier.weight(1f))
            Text(durationLine(preview), color = Theme.muted, fontWeight = FontWeight.SemiBold)
        }
        val head = model.playheadU(i)
        CurveGraph(points, selected, head,
            change = { pts, sel -> points = pts; selected = sel },
            commit = { model.setCurve(points) },
            scrubU = { u -> scrub(model.timeAtU(i, u)) })
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            TextButton({ points = SpeedCurve.flat(1.0); selected = null; model.setCurve(points) },
                Modifier.background(Theme.panel2, RoundedCornerShape(50))) { Text(loc("Reset curve"), color = Color.White) }
            val sel = selected
            TextButton({
                if (sel != null && sel > 0 && sel < points.size - 1) {
                    points = points.toMutableList().also { it.removeAt(sel) }; selected = null; model.setCurve(points)
                }
            }, Modifier.background(Theme.panel2, RoundedCornerShape(50)), enabled = sel != null && sel > 0 && sel < points.size - 1) {
                Text(loc("Delete"), color = Color.White)
            }
        }
    }
    Column(Modifier.fillMaxWidth().background(Theme.panel2, RoundedCornerShape(14.dp))) {
        OnOffRow("Keep pitch", isOn = clip.pitchCorrect) { model.setPitch(it) }
        if (tab == 1) OnOffRow("Stick to frames",
            subtitle = if (clip.sticksCurve) "Trimming keeps the points on their frames" else "The curve stretches with the clip",
            isOn = clip.sticksCurve) { model.setCurveSticks(it) }
    }
}

@Composable
private fun CurveGraph(points: List<SpeedPoint>, selected: Int?, head: Double?,
                       change: (List<SpeedPoint>, Int?) -> Unit, commit: () -> Unit, scrubU: (Double) -> Unit) {
    var drag by remember { mutableStateOf<Int?>(null) }   // point index, -1 scrubbing
    var grabHead by remember { mutableStateOf<Double?>(null) }
    var pts by remember { mutableStateOf(points) }
    LaunchedEffect(points) { pts = points }

    Box(
        Modifier.fillMaxWidth().height(190.dp).background(Theme.panel2, RoundedCornerShape(14.dp))
            .pointerInput(Unit) {
                val w = size.width.toFloat(); val h = size.height.toFloat()
                fun yFor(v: Double) = (SpeedScale.graphY(v) * h).toFloat()
                fun pointAt(o: Offset): Int? = pts.indices.filter { hypot(pts[it].t * w - o.x, yFor(pts[it].v) - o.y) < 26 * density }
                    .minByOrNull { hypot(pts[it].t * w - o.x, yFor(pts[it].v) - o.y) }
                fun onLine(o: Offset): Boolean { val u = o.x / w; return abs(yFor(SpeedCurve.value(pts, u.toDouble())) - o.y) < 18 * density && u > 0.02 && u < 0.98 }
                detectTapGestures { o ->
                    val p = pointAt(o)
                    if (p != null) { change(pts, p); scrubU(pts[p].t); return@detectTapGestures }
                    if (onLine(o)) {
                        val u = (o.x / w).toDouble()
                        if (pts.none { abs(it.t - u) < 0.03 }) {
                            val n = SpeedPoint(u, Math.round(SpeedCurve.value(pts, u) * 100) / 100.0)
                            val list = (pts + n).sortedBy { it.t }
                            pts = list; change(list, list.indexOf(n)); commit()
                        }
                    } else scrubU((o.x / w).toDouble().coerceIn(0.0, 1.0))
                }
            }
            .pointerInput(Unit) {
                val w = size.width.toFloat(); val h = size.height.toFloat()
                fun yFor(v: Double) = (SpeedScale.graphY(v) * h).toFloat()
                detectDragGestures(
                    onDragStart = { o ->
                        grabHead = head
                        val p = pts.indices.filter { hypot(pts[it].t * w - o.x, yFor(pts[it].v) - o.y) < 26 * density }
                            .minByOrNull { hypot(pts[it].t * w - o.x, yFor(pts[it].v) - o.y) }
                        drag = when {
                            p != null -> p
                            abs(yFor(SpeedCurve.value(pts, (o.x / w).toDouble())) - o.y) < 18 * density -> {
                                val u = (o.x / w).toDouble()
                                val n = SpeedPoint(u, Math.round(SpeedCurve.value(pts, u) * 100) / 100.0)
                                pts = (pts + n).sortedBy { it.t }
                                pts.indexOf(n)
                            }
                            else -> -1
                        }
                        drag?.takeIf { it >= 0 }?.let { change(pts, it) }
                    },
                    onDragEnd = { if ((drag ?: -1) >= 0) commit(); drag = null },
                    onDragCancel = { drag = null },
                ) { change, _ ->
                    val i = drag ?: return@detectDragGestures
                    val at = change.position
                    if (i < 0) { scrubU((at.x / w).toDouble().coerceIn(0.0, 1.0)); return@detectDragGestures }
                    var p = pts[i]
                    if (i > 0 && i < pts.size - 1) {
                        val lo = pts[i - 1].t + 0.02; val hi = pts[i + 1].t - 0.02
                        var t = (at.x / w).toDouble()
                        val gh = grabHead
                        if (gh != null && abs((gh - t) * w) < 10 * density && gh > lo && gh < hi) t = gh
                        p = p.copy(t = t.coerceIn(lo, hi))
                    }
                    var v = SpeedScale.graphValue((at.y / h).toDouble())
                    if (abs(log10(v)) < 0.04) v = 1.0
                    p = p.copy(v = Math.round(v * 100) / 100.0)
                    val moved = p.t != pts[i].t
                    pts = pts.toMutableList().also { it[i] = p }
                    change(pts, i)
                    if (moved || i == 0 || i == pts.size - 1) scrubU(p.t)
                }
            },
    ) {
        Canvas(Modifier.fillMaxWidth().height(190.dp)) {
            val w = size.width; val h = size.height
            fun yFor(v: Double) = (SpeedScale.graphY(v) * h).toFloat()
            for (v in listOf(15.0, 4.0, 1.0, 0.5, 0.25, 0.1)) {
                val y = yFor(v).coerceIn(1f, h - 1)
                drawLine(Color.White.copy(alpha = if (v == 1.0) 0.3f else 0.12f), Offset(0f, y), Offset(w, y), strokeWidth = density,
                         pathEffect = if (v == 1.0) null else PathEffect.dashPathEffect(floatArrayOf(4 * density, 4 * density)))
            }
            val path = Path()
            for (k in 0..120) {
                val u = k / 120.0
                val x = (u * w).toFloat(); val y = yFor(SpeedCurve.value(pts, u))
                if (k == 0) path.moveTo(x, y) else path.lineTo(x, y)
            }
            drawPath(path, Theme.accent, style = Stroke(3 * density))
            head?.let { val x = (it * w).toFloat().coerceIn(1f, w - 1); drawLine(Color.White, Offset(x, 0f), Offset(x, h), strokeWidth = 2 * density) }
            pts.forEachIndexed { k, p ->
                val c = Offset((p.t * w).toFloat(), yFor(p.v))
                val r = (if (k == selected) 10 else 8) * density
                drawCircle(if (k == selected) Theme.accent else Theme.panel2, r, c)
                drawCircle(if (k == selected) Color.Black else Color.White, r, c, style = Stroke(2.5f * density))
            }
        }
        drag?.takeIf { it >= 0 && it < pts.size }?.let {
            Text(fmtSpeed(pts[it].v), color = Color.Black, fontWeight = FontWeight.Black,
                 modifier = Modifier.align(Alignment.TopCenter).padding(6.dp).background(Theme.accent, RoundedCornerShape(50)).padding(horizontal = 10.dp, vertical = 4.dp))
        }
    }
}

private fun fmtSpeed(v: Double) = cz.krechler.bombocut.app.fmt(if (v < 1) "%.2fx" else "%.1fx", v)

/** Where the playhead is along clip i (0...1 of its source), nil when it is on another clip. */
fun EditorModel.playheadU(i: Int): Double? {
    val c = project.clips[i]
    val start = project.clipStarts[i]
    if (currentTime < start - 1e-6 || currentTime > start + c.duration + 1e-6) return null
    val len = c.outPoint - c.inPoint
    if (len <= 0) return null
    return ((c.retime.source(currentTime - start) - c.inPoint) / len).coerceIn(0.0, 1.0)
}

/** Timeline time of position u (0...1 of clip i's source). */
fun EditorModel.timeAtU(i: Int, u: Double): Double {
    val c = project.clips[i]
    val src = c.inPoint + u.coerceIn(0.0, 1.0) * (c.outPoint - c.inPoint)
    return project.clipStarts[i] + minOf(c.retime.local(src), maxOf(c.duration - 0.001, 0.0))
}

@Composable
fun VolumeSheet(model: EditorModel) {
    val i = model.selectedIndex ?: return
    val c = model.project.clips[i]
    var vol by remember(c.id) { mutableStateOf(c.volume) }
    var fin by remember(c.id) { mutableStateOf(c.fadeIn) }
    var fout by remember(c.id) { mutableStateOf(c.fadeOut) }
    val most = maxOf(0.1, minOf(cz.krechler.bombocut.model.Fade.most, c.duration / 2))
    Text(loc("Volume"), color = Theme.muted, fontWeight = FontWeight.Bold)
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.weight(1f)) { BSlider(vol, 0.0..1.0, { vol = it }, { model.setVolume(vol) }) }
        Text(cz.krechler.bombocut.app.fmt("%d %%", Math.round(vol * 100)), color = Color.White, fontWeight = FontWeight.Bold,
             modifier = Modifier.padding(start = 12.dp))
    }
    for ((title, value, set) in listOf(
        Triple("Fade in", fin, { v: Double -> fin = v }),
        Triple("Fade out", fout, { v: Double -> fout = v }))) {
        Row { Text(loc(title), color = Theme.muted, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
              Text(if (value < 0.05) loc("Off") else cz.krechler.bombocut.app.fmt("%.1f s", minOf(value, most)), color = Color.White) }
        BSlider(minOf(value, most), 0.0..most, set, { model.setClipFade(fin, fout) })
    }
}
