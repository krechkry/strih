// Stand-in for Bombocut/Engine/ModelDownload.swift + SpeechModels (iOS a28b16c): the speech model, downloaded once,
// kept on the phone, then everything runs offline. iOS runs Parakeet Ultra through FluidAudio / Core ML; Android runs
// the same model (Moondream's re-training of NVIDIA Parakeet TDT 0.6B v3) as sherpa-onnx int8 files.
// Download: plain HTTPS with Range requests (resumes where it stopped), each file checked by size and SHA-256.
package cz.krechler.bombocut.engine

import cz.krechler.bombocut.model.Paths
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest

object SpeechModel {
    /** Folder name, also the version: a new model gets a new folder (the old one is removed). */
    const val VERSION = "parakeet-ultra-int8-1"

    /** One file of the model (from the model card: tpmaerk/parakeet-ultra-sherpa-onnx-int8, CC BY 4.0). */
    data class Part(val name: String, val bytes: Long, val sha256: String)

    // TODO(mirror): serve these from Krystof's own GitHub release / Hugging Face once mirrored (same files, same hashes)
    private const val BASE = "https://huggingface.co/tpmaerk/parakeet-ultra-sherpa-onnx-int8/resolve/main/"

    val parts = listOf(
        Part("encoder.int8.onnx", 652_282_347, "f4d06712d32431b1718eceba2153c314ac4425e8fe708a3534f5e56c5ad53697"),
        Part("decoder.int8.onnx", 11_845_275, "94373c6405c8149d1c9d1e9862514e0e3e88dab1c7de18fac9d5df9c6ba5efdd"),
        Part("joiner.int8.onnx", 6_355_277, "8a71aaccfdba3d451775507a889afd2257d2e754463fd81095a8c8f290f924c2"),
        Part("tokens.txt", 93_939, "d58544679ea4bc6ac563d1f545eb7d474bd6cfa467f0a6e2c1dc1c7d37e3c35d"),
    )
    val totalBytes: Long = parts.sumOf { it.bytes }

    val folder: File get() = File(File(Paths.docs, "Models"), VERSION)
    fun file(name: String) = File(folder, name)
    private fun partial(p: Part) = File(folder, p.name + ".part")
    private fun checked() = File(folder, ".checked")

    /** Every file is there and was checked once (checking 650 MB again on every start would be slow). */
    val isReady: Boolean get() = checked().exists() && parts.all { file(it.name).length() == it.bytes }

    /** Bytes on the phone so far (finished and partial files), for the progress and the Storage screen. */
    fun downloadedBytes(): Long = parts.sumOf { p -> file(p.name).takeIf { it.exists() }?.length() ?: partial(p).length() }

    fun delete() { folder.deleteRecursively() }

    /**
     * Downloads what is missing, resuming partial files. `progress` gets 0...1 of the whole model. Blocking: run it
     * on a background thread; `cancelled` is asked between chunks (the partial file stays for next time).
     */
    fun download(progress: (Double) -> Unit, cancelled: () -> Boolean = { false }) {
        if (isReady) { progress(1.0); return }
        folder.mkdirs()
        // older model folders go (a new model replaces them)
        folder.parentFile?.listFiles()?.filter { it.isDirectory && it.name != VERSION }?.forEach { it.deleteRecursively() }
        for (p in parts) {
            val done = file(p.name)
            if (done.length() == p.bytes) continue
            done.delete()
            val part = partial(p)
            if (part.length() > p.bytes) part.delete()
            var attempts = 0
            while (part.length() < p.bytes) {
                if (cancelled()) throw IOException("cancelled")
                try {
                    fetch(p, part, progress, cancelled)
                } catch (e: IOException) {
                    if (cancelled() || ++attempts >= 5) throw e
                    Thread.sleep(1500L * attempts)
                }
            }
            if (sha256(part) != p.sha256) { part.delete(); throw IOException("The speech model download was damaged. Try again.") }
            if (!part.renameTo(done)) throw IOException("Could not save the speech model.")
        }
        checked().writeText(VERSION)
        progress(1.0)
    }

    private fun fetch(p: Part, part: File, progress: (Double) -> Unit, cancelled: () -> Boolean) {
        val have = part.length()
        val c = URL(BASE + p.name).openConnection() as HttpURLConnection
        c.connectTimeout = 20_000; c.readTimeout = 30_000
        c.instanceFollowRedirects = true
        if (have > 0) c.setRequestProperty("Range", "bytes=$have-")
        val code = c.responseCode
        if (code != 200 && code != 206) throw IOException("Speech model download failed ($code).")
        // a server that ignores the range sends everything again: start the file over
        val append = code == 206
        val before = parts.takeWhile { it != p }.sumOf { it.bytes }
        c.inputStream.use { input ->
            FileOutputStream(part, append).use { out ->
                val buf = ByteArray(256 * 1024)
                var got = if (append) have else 0L
                var last = 0L
                while (true) {
                    if (cancelled()) throw IOException("cancelled")
                    val n = input.read(buf)
                    if (n < 0) break
                    out.write(buf, 0, n)
                    got += n
                    if (got - last > 2_000_000) { last = got; progress((before + got).toDouble() / totalBytes) }
                }
            }
        }
        c.disconnect()
    }

    private fun sha256(f: File): String {
        val md = MessageDigest.getInstance("SHA-256")
        f.inputStream().use { i -> val b = ByteArray(1 shl 20); while (true) { val n = i.read(b); if (n < 0) break; md.update(b, 0, n) } }
        return md.digest().joinToString("") { "%02x".format(it) }
    }
}
