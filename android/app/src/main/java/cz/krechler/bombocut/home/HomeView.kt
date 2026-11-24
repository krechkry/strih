// Stand-in for Bombocut/Home/HomeView.swift until the real port (hours 6 to 8 of the plan).
package cz.krechler.bombocut.home

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import cz.krechler.bombocut.app.Theme
import cz.krechler.bombocut.app.loc

@Composable
fun HomeView() {
    Column(
        Modifier.fillMaxSize().background(Theme.bg).safeDrawingPadding().padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Text("BOMBOCUT", color = Theme.accent, fontSize = 34.sp, fontWeight = FontWeight.Black)
        Text(loc("Projects"), color = Color.White, fontSize = 17.sp, fontWeight = FontWeight.Bold,
             modifier = Modifier.padding(top = 12.dp))
    }
}
