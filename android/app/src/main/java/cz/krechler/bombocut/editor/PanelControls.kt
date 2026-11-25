// Bombocut's panel pieces (Editor/PanelControls.swift, BSlider.swift, Sheets.swift Panel): a bottom panel with a
// done check, a lime slider, an on / off row.
package cz.krechler.bombocut.editor

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import cz.krechler.bombocut.app.Theme
import cz.krechler.bombocut.app.loc

/** The bottom panel: rounded top, the lime check closes it. */
@Composable
fun Panel(height: Dp, close: () -> Unit, content: @Composable ColumnScope.() -> Unit) {
    // Back closes the panel, not the project
    androidx.activity.compose.BackHandler(onBack = close)
    Column(
        Modifier.fillMaxWidth().heightIn(max = height)
            .background(Theme.panel, RoundedCornerShape(topStart = 22.dp, topEnd = 22.dp)),
    ) {
        Row(Modifier.fillMaxWidth().padding(end = 8.dp, top = 4.dp), horizontalArrangement = Arrangement.End) {
            IconButton(close) { Icon(Icons.Filled.Check, loc("Done"), tint = Theme.accent) }
        }
        Column(
            Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(start = 20.dp, end = 20.dp, bottom = 20.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
            content = content,
        )
    }
}

/** BSlider: lime on dark, `done` when the finger lifts (one undo step). */
@Composable
fun BSlider(value: Double, range: ClosedFloatingPointRange<Double>, change: (Double) -> Unit, done: () -> Unit = {}) {
    Slider(
        value = value.toFloat(),
        onValueChange = { change(it.toDouble()) },
        onValueChangeFinished = done,
        valueRange = range.start.toFloat()..range.endInclusive.toFloat(),
        colors = SliderDefaults.colors(thumbColor = Color.White, activeTrackColor = Theme.accent, inactiveTrackColor = Theme.panel2),
    )
}

@Composable
fun OnOffRow(title: String, subtitle: String? = null, isOn: Boolean, set: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 14.dp).heightIn(min = 50.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(loc(title), color = Color.White, fontWeight = FontWeight.SemiBold)
            subtitle?.let { Text(loc(it), color = Theme.muted, fontSize = 12.sp, fontWeight = FontWeight.SemiBold) }
        }
        Spacer(Modifier.padding(4.dp))
        Switch(isOn, set, colors = SwitchDefaults.colors(checkedTrackColor = Theme.accent, checkedThumbColor = Color.Black))
    }
}
