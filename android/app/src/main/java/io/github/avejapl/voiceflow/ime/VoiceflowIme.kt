package io.github.avejapl.voiceflow.ime

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.inputmethodservice.InputMethodService
import android.os.Build
import android.util.Log
import android.view.KeyEvent
import android.view.View
import androidx.core.content.ContextCompat
import io.github.avejapl.voiceflow.BuildConfig
import io.github.avejapl.voiceflow.MainActivity
import io.github.avejapl.voiceflow.R
import io.github.avejapl.voiceflow.Settings
import io.github.avejapl.voiceflow.audio.Recorder
import io.github.avejapl.voiceflow.audio.WavFile
import io.github.avejapl.voiceflow.model.ModelManager
import io.github.avejapl.voiceflow.whisper.WhisperContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import java.io.File

private const val TAG = "voiceflow-ime"

/**
 * The keyboard itself: a microphone panel. Tap to record, tap to stop —
 * the transcription is committed into whatever field has focus, which is
 * the Android mirror of the desktop hotkey flow.
 */
class VoiceflowIme : InputMethodService() {

    private enum class State { IDLE, RECORDING, TRANSCRIBING }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val recorder = Recorder()
    private var whisper: WhisperContext? = null
    private var loadedModelFile: String? = null
    private var state = State.IDLE
    private var view: KeyboardView? = null
    private var debugReceiver: BroadcastReceiver? = null

    override fun onCreate() {
        super.onCreate()
        if (BuildConfig.DEBUG) {
            registerDebugReceiver()
        }
    }

    override fun onCreateInputView(): View {
        val v = KeyboardView(this)
        v.onMicTap = { toggleRecording() }
        v.onBackspace = { sendDownUpKeyEvents(KeyEvent.KEYCODE_DEL) }
        v.onSpace = { currentInputConnection?.commitText(" ", 1) }
        v.onEnter = { sendDownUpKeyEvents(KeyEvent.KEYCODE_ENTER) }
        v.onSwitchKeyboard = { switchBack() }
        v.onOpenApp = { openSetup() }
        view = v
        applyState(State.IDLE)
        return v
    }

    override fun onStartInputView(info: android.view.inputmethod.EditorInfo?, restarting: Boolean) {
        super.onStartInputView(info, restarting)
        applyState(State.IDLE)
        view?.setReady(isReady())
    }

    override fun onFinishInputView(finishingInput: Boolean) {
        // Leaving the field mid-recording: drop the audio, never paste blind.
        if (state == State.RECORDING) {
            recorder.stop()
            applyState(State.IDLE)
        }
        super.onFinishInputView(finishingInput)
    }

    override fun onDestroy() {
        debugReceiver?.let { unregisterReceiver(it) }
        if (state == State.RECORDING) recorder.stop()
        runBlocking { whisper?.release() }
        whisper = null
        scope.cancel()
        super.onDestroy()
    }

    // -- dictation flow ----------------------------------------------------

    private fun isReady(): Boolean {
        val settings = Settings(this)
        val hasMic = ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) ==
                PackageManager.PERMISSION_GRANTED
        return hasMic && ModelManager.isDownloaded(this, ModelManager.spec(settings.modelId))
    }

    private fun toggleRecording() {
        when (state) {
            State.TRANSCRIBING -> Unit // busy; ignore taps
            State.RECORDING -> finishRecording()
            State.IDLE -> {
                if (!isReady()) {
                    openSetup()
                    return
                }
                if (recorder.start()) {
                    applyState(State.RECORDING)
                    pollLevel()
                } else {
                    view?.showStatus(getString(R.string.status_mic_error))
                }
            }
        }
    }

    private fun finishRecording() {
        val audio = recorder.stop()
        if (audio.size < 8000) { // <0.5 s — an accidental tap, not speech
            applyState(State.IDLE)
            return
        }
        applyState(State.TRANSCRIBING)
        scope.launch {
            try {
                val text = transcribe(audio)
                if (text.isNotBlank()) {
                    currentInputConnection?.commitText(text, 1)
                }
            } catch (e: Exception) {
                Log.w(TAG, "transcription failed", e)
                view?.showStatus(getString(R.string.status_error))
            } finally {
                applyState(State.IDLE)
            }
        }
    }

    private suspend fun transcribe(audio: FloatArray, modelOverride: String? = null): String {
        val settings = Settings(this)
        val spec = ModelManager.spec(modelOverride ?: settings.modelId)
        val file = ModelManager.localFile(this, spec)
        val ctx = ensureContext(file)
        return ctx.transcribe(audio, settings.language, settings.vocabularyPrompt)
    }

    private suspend fun ensureContext(modelFile: File): WhisperContext {
        val current = whisper
        if (current != null && loadedModelFile == modelFile.absolutePath) return current
        current?.release()
        val fresh = withContext(Dispatchers.IO) { WhisperContext.create(modelFile) }
        whisper = fresh
        loadedModelFile = modelFile.absolutePath
        return fresh
    }

    private fun pollLevel() {
        view?.postDelayed({
            if (state == State.RECORDING) {
                view?.setLevel(recorder.lastLevel)
                pollLevel()
            }
        }, 50)
    }

    // -- plumbing ----------------------------------------------------------

    private fun applyState(newState: State) {
        state = newState
        view?.setState(
            recording = newState == State.RECORDING,
            transcribing = newState == State.TRANSCRIBING,
        )
    }

    private fun switchBack() {
        if (Build.VERSION.SDK_INT >= 28) {
            switchToPreviousInputMethod()
        } else {
            @Suppress("DEPRECATION")
            window.window?.let {
                val imm = getSystemService(Context.INPUT_METHOD_SERVICE)
                        as android.view.inputmethod.InputMethodManager
                imm.showInputMethodPicker()
            }
        }
    }

    private fun openSetup() {
        startActivity(
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        )
    }

    // -- debug hook --------------------------------------------------------

    /**
     * Debug builds accept a broadcast that transcribes a WAV from disk and
     * commits the result — the emulator has no real microphone, and this is
     * the Android counterpart of the desktop's hardware-free tests:
     *
     *   adb shell am broadcast -a io.github.avejapl.voiceflow.DEBUG_TRANSCRIBE \
     *       --es path /data/local/tmp/sample.wav io.github.avejapl.voiceflow.debug
     */
    private fun registerDebugReceiver() {
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                val path = intent.getStringExtra("path") ?: return
                val model = intent.getStringExtra("model")
                Log.i(TAG, "debug transcribe: $path (model=$model)")
                scope.launch {
                    try {
                        val audio = withContext(Dispatchers.IO) { WavFile.readMono16k(File(path)) }
                        val text = transcribe(audio, model)
                        Log.i(TAG, "debug result: $text")
                        currentInputConnection?.commitText(text, 1)
                    } catch (e: Exception) {
                        Log.w(TAG, "debug transcribe failed", e)
                    }
                }
            }
        }
        val filter = IntentFilter("io.github.avejapl.voiceflow.DEBUG_TRANSCRIBE")
        if (Build.VERSION.SDK_INT >= 33) {
            registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            registerReceiver(receiver, filter)
        }
        debugReceiver = receiver
    }
}
