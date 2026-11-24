// Part port of Bombocut/Editor/AdjustSheet.swift (iOS ad3827a): the Basic tab on the clip's fixed look.
// Not yet: keyframes, the Advanced tab (curves, HSL), Effects tab, live preview while dragging, Apply to.
package cz.krechler.bombocut.editor

import androidx.compose.foundation.layout.Row
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import cz.krechler.bombocut.app.Theme
import cz.krechler.bombocut.app.loc
import cz.krechler.bombocut.model.LookParam

fun EditorModel.setLook(p: LookParam, v: Double) {
    val i = selectedIndex ?: return
    val c = project.clips[i]
    val n = c.withStaticLook(p.set(c.staticLook, v))
    if (n == c) return
    mutate { pr -> pr.copy(clips = pr.clips.toMutableList().also { it[i] = n }) }
}

@Composable
fun AdjustSheet(model: EditorModel) {
    val i = model.selectedIndex ?: return
    val c = model.project.clips[i]
    for (p in LookParam.basic) {
        var v by remember(c.id, p, c.staticLook) { mutableStateOf(p.get(c.staticLook)) }
        Row {
            Text(loc(p.title), color = Theme.muted, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
            Text(p.display(v), color = Color.White, fontWeight = FontWeight.Bold)
        }
        BSlider(v, p.range.start..p.range.endInclusive, { v = it }, { model.setLook(p, v) })
    }
}
