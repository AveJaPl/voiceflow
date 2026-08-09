package io.github.avejapl.voiceflow.whisper

import android.os.Build
import android.util.Log
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.withContext
import java.io.File
import java.util.concurrent.Executors

private const val TAG = "voiceflow-whisper"

/**
 * A loaded whisper model. All native calls run on a single dedicated thread —
 * whisper contexts are not thread-safe, and one dictation at a time is all a
 * keyboard needs.
 */
class WhisperContext private constructor(private var ptr: Long) {

    private val executor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "voiceflow-whisper").apply { priority = Thread.MAX_PRIORITY }
    }
    private val dispatcher: CoroutineDispatcher = executor.asCoroutineDispatcher()

    suspend fun transcribe(
        audio: FloatArray,
        language: String,
        vocabularyPrompt: String?,
    ): String = withContext(dispatcher) {
        check(ptr != 0L) { "context released" }
        val threads = Runtime.getRuntime().availableProcessors().coerceIn(2, 6)
        val started = System.currentTimeMillis()
        val text = WhisperLib.fullTranscribe(ptr, threads, language, vocabularyPrompt, audio)
        Log.i(TAG, "transcribed ${audio.size / 16000f}s in ${System.currentTimeMillis() - started}ms")
        text?.trim() ?: ""
    }

    suspend fun release() = withContext(dispatcher) {
        if (ptr != 0L) {
            WhisperLib.freeContext(ptr)
            ptr = 0L
        }
        executor.shutdown()
    }

    companion object {
        fun create(modelFile: File): WhisperContext {
            val ptr = WhisperLib.initContext(modelFile.absolutePath)
            check(ptr != 0L) { "Nie można załadować modelu: ${modelFile.name}" }
            return WhisperContext(ptr)
        }
    }
}

object WhisperLib {
    init {
        // The arm64 fp16 build is measurably faster on modern phones; fall
        // back to the portable build elsewhere (incl. x86_64 emulator).
        var loaded = false
        if (Build.SUPPORTED_ABIS.firstOrNull() == "arm64-v8a") {
            val info = cpuInfo()
            if (info?.contains("fphp") == true) {
                try {
                    System.loadLibrary("voiceflow_v8fp16_va")
                    Log.i(TAG, "loaded voiceflow_v8fp16_va")
                    loaded = true
                } catch (e: UnsatisfiedLinkError) {
                    Log.w(TAG, "fp16 lib unavailable: $e")
                }
            }
        }
        if (!loaded) {
            System.loadLibrary("voiceflow")
            Log.i(TAG, "loaded voiceflow (portable)")
        }
    }

    private fun cpuInfo(): String? = try {
        File("/proc/cpuinfo").readText()
    } catch (e: Exception) {
        null
    }

    external fun initContext(modelPath: String): Long
    external fun freeContext(contextPtr: Long)
    external fun fullTranscribe(
        contextPtr: Long,
        numThreads: Int,
        language: String,
        prompt: String?,
        audioData: FloatArray,
    ): String?

    external fun getSystemInfo(): String
}
