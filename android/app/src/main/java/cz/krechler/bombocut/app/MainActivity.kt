package cz.krechler.bombocut.app

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import cz.krechler.bombocut.home.HomeView

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        AppLanguage.load(this)
        enableEdgeToEdge()
        setContent { BombocutTheme { HomeView() } }
    }
}
