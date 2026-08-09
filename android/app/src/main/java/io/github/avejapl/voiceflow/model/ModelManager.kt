package io.github.avejapl.voiceflow.model

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.net.HttpURLConnection
import java.net.URL

/**
 * Downloads and locates ggml model files. Models live in the app's private
 * files dir; nothing is bundled in the APK (a keyboard should not weigh
 * hundreds of MB in the store listing).
 */
object ModelManager {

    data class ModelSpec(
        val id: String,
        val fileName: String,
        val sizeMb: Int,
        val description: String,
    ) {
        val url: String
            get() = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$fileName"
    }

    // q5_1 quantizations: the accuracy loss is inaudible in dictation use,
    // the size and speed win on phones is large.
    val MODELS = listOf(
        ModelSpec("tiny", "ggml-tiny-q5_1.bin", 32, "najszybszy, najsłabsza jakość"),
        ModelSpec("base", "ggml-base-q5_1.bin", 60, "szybki, jakość podstawowa"),
        ModelSpec("small", "ggml-small-q5_1.bin", 190, "zalecany — dobra jakość polskiego"),
    )

    val DEFAULT = MODELS.last()

    fun spec(id: String): ModelSpec = MODELS.firstOrNull { it.id == id } ?: DEFAULT

    fun modelsDir(context: Context): File =
        File(context.filesDir, "models").apply { mkdirs() }

    fun localFile(context: Context, spec: ModelSpec): File =
        File(modelsDir(context), spec.fileName)

    fun isDownloaded(context: Context, spec: ModelSpec): Boolean {
        val f = localFile(context, spec)
        // Guard against a previous interrupted download: ggml files start
        // with the magic "lsmg"/GGUF header and are never this small.
        return f.exists() && f.length() > 1_000_000
    }

    /**
     * Streams the model to disk, reporting progress in [0..1]. Downloads to a
     * temp file and renames at the end so an interrupted download never
     * masquerades as a complete model.
     */
    suspend fun download(
        context: Context,
        spec: ModelSpec,
        onProgress: (Float) -> Unit,
    ): File = withContext(Dispatchers.IO) {
        val target = localFile(context, spec)
        if (isDownloaded(context, spec)) return@withContext target
        val tmp = File(target.parentFile, "${target.name}.part")

        var connection: HttpURLConnection? = null
        try {
            connection = URL(spec.url).openConnection() as HttpURLConnection
            connection.instanceFollowRedirects = true
            connection.connectTimeout = 15_000
            connection.readTimeout = 30_000
            connection.connect()
            if (connection.responseCode !in 200..299) {
                throw IllegalStateException("HTTP ${connection.responseCode} dla ${spec.url}")
            }
            val total = connection.contentLengthLong
            connection.inputStream.use { input ->
                tmp.outputStream().use { output ->
                    val buf = ByteArray(256 * 1024)
                    var done = 0L
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        output.write(buf, 0, n)
                        done += n
                        if (total > 0) onProgress(done.toFloat() / total)
                    }
                }
            }
            if (!tmp.renameTo(target)) {
                throw IllegalStateException("Nie można zapisać ${target.name}")
            }
            onProgress(1f)
            target
        } finally {
            connection?.disconnect()
            tmp.delete()
        }
    }
}
