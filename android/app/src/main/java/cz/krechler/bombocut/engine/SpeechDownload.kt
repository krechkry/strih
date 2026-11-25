// Stand-in for Bombocut/Engine/ModelDownload.swift's control side (start, pause, resume, discard) + SpeechModels.state:
// one download of the speech model for the whole app, so the Captions panel and the Storage screen show and steer the
// same thing. It keeps going when the panel closes; a pause keeps the partial files (resumed with Range requests).
package cz.krechler.bombocut.engine

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import cz.krechler.bombocut.app.loc
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.IOException

object SpeechDownload {
    sealed class State {
        data object Missing : State()
        data class Downloading(val fraction: Double) : State()
        data class Paused(val fraction: Double) : State()
        data class Failed(val message: String, val fraction: Double) : State()
        data object Ready : State()
    }

    /** Where the model stands; read by Compose (snapshot state), written on the main thread. */
    var state by mutableStateOf(initial())
        private set

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var job: Job? = null
    private var pausing = false
    private var deleting: Job? = null

    private fun fraction() = SpeechModel.downloadedBytes().toDouble() / SpeechModel.totalBytes

    /** On start: ready, or part way (shown as paused, one tap continues), or nothing yet. */
    private fun initial(): State = when {
        SpeechModel.isReady -> State.Ready
        SpeechModel.downloadedBytes() > 0 -> State.Paused(fraction())
        else -> State.Missing
    }

    val isRunning: Boolean get() = job?.isActive == true

    /** Start, or continue where it stopped. */
    fun start() {
        if (isRunning) return
        if (SpeechModel.isReady) { state = State.Ready; return }
        pausing = false
        state = State.Downloading(fraction())
        val main = android.os.Handler(android.os.Looper.getMainLooper())
        val after = deleting
        job = scope.launch {
            after?.join()
            try {
                withContext(Dispatchers.IO) {
                    val j = coroutineContext.job
                    SpeechModel.download({ f -> main.post { if (state is State.Downloading) state = State.Downloading(f) } },
                                         cancelled = { !j.isActive || pausing })
                }
                state = State.Ready
            } catch (e: Exception) {
                state = if (state == State.Missing) State.Missing
                        else if (pausing || e is kotlinx.coroutines.CancellationException) State.Paused(fraction())
                        else State.Failed(e.message?.takeIf { it.isNotBlank() } ?: loc("Download failed"), fraction())
            }
        }
    }

    /** Stops for now; the downloaded part stays for later. */
    fun pause() {
        if (!isRunning) return
        pausing = true
        job?.cancel()
        state = State.Paused(fraction())
    }

    /** The model gone from the phone (Storage), downloaded or part way. */
    fun delete() {
        pausing = true
        val running = job
        job = null
        state = State.Missing
        // the download thread stops at its next chunk; only then the files go (nothing half-written comes back)
        deleting = scope.launch {
            running?.cancel()
            running?.join()
            withContext(Dispatchers.IO) { SpeechModel.delete() }
            state = State.Missing
        }
    }

    /**
     * Waits until the model is on the phone, starting the download if nothing is going on. A pause keeps waiting (the
     * panel shows Resume, like iOS); a failed download throws. `report` gets every state while waiting.
     */
    suspend fun await(report: (State) -> Unit) {
        if (SpeechModel.isReady) { state = State.Ready; return }
        if (state !is State.Paused) start()
        val end = snapshotFlow { state }.first { report(it); it is State.Ready || it is State.Failed }
        if (end is State.Failed) throw IOException(end.message)
    }

    /** Whether the phone is on mobile data (or another network that costs) right now: big downloads ask first. */
    fun onMobileData(context: Context): Boolean {
        val cm = context.getSystemService(ConnectivityManager::class.java) ?: return false
        val caps = runCatching { cm.getNetworkCapabilities(cm.activeNetwork) }.getOrNull() ?: return false
        return !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
    }
}
