package io.github.avejapl.voiceflow.audio

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.util.Log
import java.util.concurrent.atomic.AtomicBoolean

private const val TAG = "voiceflow-rec"
private const val SAMPLE_RATE = 16_000

/**
 * Records 16 kHz mono PCM into memory as the float array whisper expects.
 *
 * Capped at [maxSeconds] as a safety net (same rule as the desktop
 * `audio.max_seconds`), which also bounds memory: 5 minutes of float PCM
 * is ~19 MB.
 */
class Recorder(private val maxSeconds: Int = 300) {

    private var record: AudioRecord? = null
    private var thread: Thread? = null
    private val recording = AtomicBoolean(false)
    private var buffer = FloatArray(0)
    private var written = 0

    val isRecording: Boolean get() = recording.get()

    /** Peak amplitude (0..1) of the most recent chunk, for the level meter. */
    @Volatile var lastLevel: Float = 0f
        private set

    /** 1 for native 16 kHz capture, 3 when falling back to 48 kHz. */
    private var decimation = 1

    @SuppressLint("MissingPermission") // caller checks RECORD_AUDIO
    fun start(): Boolean {
        if (recording.get()) return true
        // 16 kHz is what whisper wants but the CDD only guarantees 44.1/48 kHz;
        // if the device refuses, capture at 48 kHz and decimate by 3.
        var rate = SAMPLE_RATE
        decimation = 1
        var minBuf = AudioRecord.getMinBufferSize(
            rate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_FLOAT
        )
        var rec: AudioRecord? = if (minBuf > 0) makeRecord(rate, minBuf) else null
        if (rec == null) {
            rate = 48_000
            decimation = 3
            minBuf = AudioRecord.getMinBufferSize(
                rate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_FLOAT
            )
            rec = if (minBuf > 0) makeRecord(rate, minBuf) else null
        }
        if (rec == null) {
            Log.w(TAG, "AudioRecord failed to initialize at 16k and 48k")
            return false
        }
        buffer = FloatArray(SAMPLE_RATE * maxSeconds)
        written = 0
        record = rec
        recording.set(true)
        rec.startRecording()
        val dec = decimation
        thread = Thread({
            val chunk = FloatArray(minBuf)
            while (recording.get() && written < buffer.size) {
                val n = rec.read(chunk, 0, chunk.size, AudioRecord.READ_BLOCKING)
                if (n > 0) {
                    var peak = 0f
                    var i = 0
                    while (i < n && written < buffer.size) {
                        val sample = chunk[i]
                        buffer[written++] = sample
                        val a = kotlin.math.abs(sample)
                        if (a > peak) peak = a
                        i += dec
                    }
                    lastLevel = peak
                }
            }
        }, "voiceflow-audio").also { it.start() }
        return true
    }

    @SuppressLint("MissingPermission")
    private fun makeRecord(rate: Int, minBuf: Int): AudioRecord? {
        val rec = AudioRecord(
            MediaRecorder.AudioSource.VOICE_RECOGNITION,
            rate,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_FLOAT,
            minBuf * 4,
        )
        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            rec.release()
            return null
        }
        return rec
    }

    /** Stops and returns the recorded samples (possibly empty). */
    fun stop(): FloatArray {
        recording.set(false)
        thread?.join(1000)
        thread = null
        record?.let {
            try {
                it.stop()
            } catch (e: IllegalStateException) {
                Log.w(TAG, "stop: $e")
            }
            it.release()
        }
        record = null
        lastLevel = 0f
        val out = buffer.copyOf(written)
        buffer = FloatArray(0)
        return out
    }
}
