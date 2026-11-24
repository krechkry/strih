package cz.krechler.bombocut.app

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

/** Dark only, lime accent, like the iPhone app. */
@Composable
fun BombocutTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = darkColorScheme(
            primary = Theme.accent,
            onPrimary = Color.Black,
            background = Theme.bg,
            surface = Theme.panel,
            surfaceVariant = Theme.panel2,
            onBackground = Color.White,
            onSurface = Color.White,
        ),
        content = content,
    )
}
