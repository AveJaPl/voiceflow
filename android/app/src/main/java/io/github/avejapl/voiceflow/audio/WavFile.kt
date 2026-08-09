package io.github.avejapl.voiceflow.audio

import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Minimal WAV reader for the debug pipeline (the emulator has no microphone;
 * tests feed audio from disk). Accepts 16-bit PCM mono at 16 kHz — the same
 * format the desktop recorder produces.
 */
object WavFile {

    fun readMono16k(file: File): FloatArray {
        val bytes = file.readBytes()
        require(bytes.size > 44) { "za krótki plik WAV" }
        val buf = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        require(bytes.copyOfRange(0, 4).decodeToString() == "RIFF") { "brak nagłówka RIFF" }
        require(bytes.copyOfRange(8, 12).decodeToString() == "WAVE") { "to nie jest WAV" }

        // Walk the chunks; fmt/data are not guaranteed to sit at fixed offsets.
        var pos = 12
        var sampleRate = 0
        var channels = 0
        var bitsPerSample = 0
        var dataOffset = -1
        var dataSize = 0
        while (pos + 8 <= bytes.size) {
            val id = bytes.copyOfRange(pos, pos + 4).decodeToString()
            val size = buf.getInt(pos + 4)
            when (id) {
                "fmt " -> {
                    channels = buf.getShort(pos + 10).toInt()
                    sampleRate = buf.getInt(pos + 12)
                    bitsPerSample = buf.getShort(pos + 22).toInt()
                }
                "data" -> {
                    dataOffset = pos + 8
                    dataSize = size
                }
            }
            pos += 8 + size + (size and 1)
        }
        require(dataOffset > 0) { "brak sekcji data" }
        require(bitsPerSample == 16) { "obsługiwane jest tylko 16-bit PCM (jest: $bitsPerSample)" }
        require(channels == 1) { "obsługiwane jest tylko mono (jest: $channels kanałów)" }
        require(sampleRate == 16_000) { "wymagane 16 kHz (jest: $sampleRate)" }

        val samples = dataSize / 2
        val out = FloatArray(samples)
        for (i in 0 until samples) {
            out[i] = buf.getShort(dataOffset + i * 2) / 32768f
        }
        return out
    }
}
