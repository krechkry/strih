// Ported from Bombocut/Editor/CaptionsSheet.swift (iOS a28b16c), the generate page: the language, the speech model
// note (downloaded once), Generate captions / New captions track, what the run is doing, what went wrong.
// Not yet: picking clips, typed names, Regenerate one line, translation.
package cz.krechler.bombocut.editor

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import cz.krechler.bombocut.app.PrefsSettings
import cz.krechler.bombocut.app.Theme
import cz.krechler.bombocut.app.loc
import cz.krechler.bombocut.app.locf
import cz.krechler.bombocut.engine.SpeechModel
import cz.krechler.bombocut.engine.Transcriber
import cz.krechler.bombocut.model.CaptionLanguage

@androidx.compose.runtime.Composable
fun CaptionsSheet(model: EditorModel) {
    val context = LocalContext.current
    val prefs = remember { PrefsSettings(context) }
    // iOS: @AppStorage("lastCaptionLanguage"); the phone's language first time, Czech when it isn't one of the 25
    var language by remember {
        mutableStateOf(prefs.string("lastCaptionLanguage")
            ?: java.util.Locale.getDefault().language.takeIf { CaptionLanguage.item(it) != null } ?: "cs")
    }
    var more by remember { mutableStateOf(false) }
    // generating again replaces your text edits: the first tap asks (iOS confirmation dialog)
    var confirm by remember { mutableStateOf(false) }
    val job = model.captionJob
    val running = job != null && job.error == null
    val hasTracks = model.project.captionTracks.isNotEmpty()

    Text(loc("Captions"), color = Color.White, fontWeight = FontWeight.Black)
    // your usual languages first, the rest behind "more"
    val mine = listOf("cs", "sk", "en", language).distinct()
    val shown = if (more) CaptionLanguage.all.map { it.code } else mine
    Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        for (code in shown) {
            val l = CaptionLanguage.item(code) ?: continue
            val on = code == language
            Text("${l.flag} ${l.name}", color = if (on) Color.Black else Color.White, fontWeight = FontWeight.Bold,
                 modifier = Modifier.background(if (on) Theme.accent else Theme.panel2, RoundedCornerShape(50))
                     .clickable(enabled = !running) { language = code; prefs.set("lastCaptionLanguage", code) }
                     .padding(horizontal = 14.dp, vertical = 8.dp))
        }
        if (!more) Text(loc("Subtitle languages") + " …", color = Theme.muted, fontWeight = FontWeight.Bold,
                        modifier = Modifier.background(Theme.panel2, RoundedCornerShape(50)).clickable { more = true }
                            .padding(horizontal = 14.dp, vertical = 8.dp))
    }

    when {
        job?.error != null -> Text(job.error, color = Color(0xFFFF453A), fontWeight = FontWeight.SemiBold)
        running -> {
            val (text, f) = when (val p = job!!.phase) {
                is Transcriber.Phase.Downloading -> locf("Downloading speech model %lld %%", (p.fraction * 100).toInt()) to p.fraction
                Transcriber.Phase.PreparingAudio -> loc("Listening to the sound…") to null
                Transcriber.Phase.LoadingModel -> loc("Preparing the model…") to null
                is Transcriber.Phase.Listening -> locf("Listening %lld %%", (p.fraction * 100).toInt()) to p.fraction
            }
            Text(text, color = Color.White, fontWeight = FontWeight.SemiBold)
            if (f != null) LinearProgressIndicator(progress = { f.toFloat() }, color = Theme.accent, trackColor = Theme.panel2,
                                                   modifier = Modifier.fillMaxWidth())
            else LinearProgressIndicator(color = Theme.accent, trackColor = Theme.panel2, modifier = Modifier.fillMaxWidth())
        }
        model.captionsReady -> Text(loc("Captions ready"), color = Theme.accent, fontWeight = FontWeight.Bold)
        !SpeechModel.isReady -> Text(loc("The speech model is about 650 MB. Wi-Fi is better."), color = Theme.muted)
    }

    if (running) {
        TextButton({ model.cancelCaptions() }, modifier = Modifier.fillMaxWidth().background(Theme.panel2, RoundedCornerShape(14.dp))) {
            Text(loc("Cancel"), color = Color.White, fontWeight = FontWeight.Bold)
        }
    } else {
        if (confirm) Text(loc("Generate captions again? Your text edits will be replaced."), color = Color.White, fontWeight = FontWeight.SemiBold)
        TextButton({
            if (hasTracks && !confirm) { confirm = true; return@TextButton }
            confirm = false
            model.startCaptions(context, language, newTrack = false)
        },
                   modifier = Modifier.fillMaxWidth().background(Theme.accent, RoundedCornerShape(14.dp))) {
            Text(loc(if (hasTracks) "Generate again" else "Generate captions"), color = Color.Black, fontWeight = FontWeight.Bold)
        }
        if (hasTracks) TextButton({ confirm = false; model.startCaptions(context, language, newTrack = true) },
                                  modifier = Modifier.fillMaxWidth().background(Theme.panel2, RoundedCornerShape(14.dp))) {
            Text(loc("New captions track"), color = Color.White, fontWeight = FontWeight.Bold)
        }
    }
    Text(loc("Automatic subtitles in 25 languages"), color = Theme.muted)
}
