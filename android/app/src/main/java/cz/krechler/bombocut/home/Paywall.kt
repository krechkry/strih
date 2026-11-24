// Ported from PaywallView in Bombocut/Home/Onboarding.swift (iOS ad3827a): start the free week, buy once, or
// after the week: buy, or export the projects as they are. The points name only what the Android app does today.
package cz.krechler.bombocut.home

import android.app.Activity
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Autorenew
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.CreditCard
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material.icons.filled.TextFields
import androidx.compose.material.icons.filled.Upload
import androidx.compose.material.icons.filled.WifiOff
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import cz.krechler.bombocut.app.Purchases
import cz.krechler.bombocut.app.Theme
import cz.krechler.bombocut.app.loc
import cz.krechler.bombocut.app.locf

enum class PaywallMode { start, buy, expired }

@Composable
fun Paywall(mode: PaywallMode, close: (() -> Unit)? = null, exportOnly: (() -> Unit)? = null) {
    val activity = LocalContext.current as? Activity
    val access by Purchases.access.collectAsState()
    val price by Purchases.price.collectAsState()
    val busy by Purchases.busy.collectAsState()
    val error by Purchases.error.collectAsState()
    val priceText = price ?: Purchases.priceText()
    LaunchedEffect(access) { if (mode == PaywallMode.buy && access == Purchases.Access.Owned) close?.invoke() }

    Box(Modifier.fillMaxSize().background(Theme.bg).safeDrawingPadding()) {
        Column(
            Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(22.dp),
            verticalArrangement = Arrangement.spacedBy(22.dp),
        ) {
            Row(Modifier.fillMaxWidth().heightIn(min = 36.dp)) {
                Spacer(Modifier.weight(1f))
                if (mode == PaywallMode.buy && close != null) {
                    IconButton(close, Modifier.size(36.dp).background(Theme.panel2, RoundedCornerShape(50))) {
                        Icon(Icons.Filled.Close, loc("Close"), tint = Color.White)
                    }
                }
            }
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(when (mode) {
                    PaywallMode.start -> loc("Try everything free for 7 days.")
                    PaywallMode.buy -> loc("Keep BOMBOCUT")
                    PaywallMode.expired -> loc("Your 7 free days are over")
                }, color = Color.White, fontSize = 32.sp, fontWeight = FontWeight.Black, lineHeight = 36.sp)
                if (mode == PaywallMode.start) {
                    // the deal in one breath, as big as the offer: nobody reads the small line
                    Text(loc("Then buy it once, or don't."), color = Theme.accent, fontSize = 32.sp, fontWeight = FontWeight.Black, lineHeight = 36.sp)
                } else {
                    val d = Purchases.daysLeft
                    Text(when (mode) {
                        PaywallMode.buy -> if (d == 1) loc("1 day of your trial left.") else locf("%lld days of your trial left.", d)
                        else -> loc("Buy BOMBOCUT once to keep editing. Your projects are safe on your phone, and you can still export them as they are.")
                    }, color = Color.White.copy(alpha = 0.75f), fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
                }
            }
            Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
                Point(Icons.Filled.Speed, "Speed curves, keyframes and color")
                Point(Icons.Filled.TextFields, "Text and captions with outlines, shadows and animations")
                Point(Icons.Filled.Upload, "Export up to 4K, at 30 or 60 fps")
                Point(Icons.Filled.WifiOff, "Everything runs offline, on your phone. No cloud, no account, no data collection.")
                Point(Icons.Filled.CreditCard, "No subscription. Pay once, no ads, nothing locked.")
                Point(Icons.Filled.Autorenew, "All updates included")
            }
            Column(
                Modifier.fillMaxWidth().background(Theme.panel, RoundedCornerShape(16.dp)).padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Filled.Favorite, null, tint = Theme.accent, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(8.dp))
                    Text(loc("Made by a filmmaker in Czechia."), color = Theme.accent, fontWeight = FontWeight.Black, fontSize = 15.sp)
                }
                Text(loc("BOMBOCUT is made by one filmmaker. Buying it keeps the updates coming, and your feedback actually matters."),
                     color = Color.White, fontWeight = FontWeight.SemiBold, fontSize = 15.sp)
            }
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                when (mode) {
                    PaywallMode.start -> {
                        Primary(loc("Start 7-day free trial"), !busy) { Purchases.startTrial(); close?.invoke() }
                        Secondary(locf("Buy once for %@", priceText), !busy) { activity?.let { Purchases.buy(it) } }
                    }
                    PaywallMode.buy, PaywallMode.expired -> {
                        Primary(locf("Buy for %@", priceText), !busy) { activity?.let { Purchases.buy(it) } }
                        if (mode == PaywallMode.expired && exportOnly != null) Secondary(loc("Export my projects as they are"), true) { exportOnly() }
                    }
                }
                if (busy) CircularProgressIndicator(color = Color.White, modifier = Modifier.align(Alignment.CenterHorizontally))
            }
            Text(locf("Not a subscription. After 7 days nothing is bought or charged by itself. The trial has every tool. Then you buy BOMBOCUT once for %@, or you don't. You can always export your projects as they are.", priceText),
                 color = Theme.muted, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
            Row {
                TextButton({ Purchases.restore() }) { Text(loc("Restore purchase"), color = Color.White.copy(alpha = 0.8f), fontWeight = FontWeight.Bold) }
            }
        }
    }
    error?.let { e ->
        AlertDialog(onDismissRequest = { Purchases.error.value = null },
            confirmButton = { TextButton({ Purchases.error.value = null }) { Text(loc("OK")) } },
            title = { Text("BOMBOCUT") }, text = { Text(e) })
    }
}

@Composable
private fun Point(icon: ImageVector, text: String) {
    Row(verticalAlignment = Alignment.Top) {
        Icon(icon, null, tint = Theme.accent, modifier = Modifier.size(24.dp))
        Spacer(Modifier.width(12.dp))
        Text(loc(text), color = Color.White, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
private fun Primary(title: String, enabled: Boolean, action: () -> Unit) {
    TextButton(action, enabled = enabled, modifier = Modifier.fillMaxWidth().heightIn(min = 56.dp).background(Theme.accent, RoundedCornerShape(16.dp))) {
        Text(title, color = Color.Black, fontWeight = FontWeight.Bold, fontSize = 17.sp)
    }
}

@Composable
private fun Secondary(title: String, enabled: Boolean, action: () -> Unit) {
    TextButton(action, enabled = enabled, modifier = Modifier.fillMaxWidth().heightIn(min = 52.dp).background(Theme.panel2, RoundedCornerShape(16.dp))) {
        Text(title, color = Color.White, fontWeight = FontWeight.Bold, fontSize = 17.sp)
    }
}
