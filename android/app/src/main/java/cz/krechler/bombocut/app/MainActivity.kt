package cz.krechler.bombocut.app

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import cz.krechler.bombocut.editor.EditorView
import cz.krechler.bombocut.home.HomeView
import cz.krechler.bombocut.home.Paywall
import cz.krechler.bombocut.home.PaywallMode
import cz.krechler.bombocut.model.Defaults
import cz.krechler.bombocut.model.Paths
import cz.krechler.bombocut.model.ProjectStore

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        AppLanguage.load(this)
        Paths.init(this)
        Defaults.store = PrefsSettings(this)
        val store = ProjectStore()
        // debug builds (CI's emulator) skip the paywall unless started with --ez paywall true
        val debuggable = (applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0
        Purchases.debugUnlocked = debuggable && !intent.getBooleanExtra("paywall", false)
        Purchases.init(this)
        enableEdgeToEdge()
        setContent {
            BombocutTheme {
                var open by rememberSaveable { mutableStateOf<String?>(null) }
                var exportOnly by rememberSaveable { mutableStateOf(false) }
                val projects by store.projects.collectAsState()
                val access by Purchases.access.collectAsState()
                val p = open?.let { id -> projects.firstOrNull { it.id.toString() == id } }
                val expired = access == Purchases.Access.Expired
                when {
                    // first launch: the free week (or buy right away)
                    access == Purchases.Access.New -> Paywall(PaywallMode.start)
                    // after the week: buy, or open the project only to export it as it is
                    p != null && expired && !exportOnly -> {
                        androidx.activity.compose.BackHandler { open = null }
                        Paywall(PaywallMode.expired, exportOnly = { exportOnly = true })
                    }
                    p != null -> EditorView(p, store, exportOnly = expired) { open = null; exportOnly = false }
                    else -> HomeView(store) { open = it.toString() }
                }
            }
        }
    }

    override fun onResume() {
        super.onResume()
        // a day may have passed, or a purchase finished elsewhere
        Purchases.recheck()
        Purchases.refresh()
    }
}
