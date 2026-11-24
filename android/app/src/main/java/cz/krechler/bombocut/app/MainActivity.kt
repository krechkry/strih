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
        enableEdgeToEdge()
        setContent {
            BombocutTheme {
                var open by rememberSaveable { mutableStateOf<String?>(null) }
                val projects by store.projects.collectAsState()
                val p = open?.let { id -> projects.firstOrNull { it.id.toString() == id } }
                if (p != null) EditorView(p) { open = null }
                else HomeView(store) { open = it.toString() }
            }
        }
    }
}
