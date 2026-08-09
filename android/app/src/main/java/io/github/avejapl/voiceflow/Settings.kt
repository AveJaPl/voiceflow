package io.github.avejapl.voiceflow

import android.content.Context
import android.content.SharedPreferences
import io.github.avejapl.voiceflow.model.ModelManager
import java.util.Locale

/**
 * Thin wrapper over SharedPreferences — the Android sibling of the desktop
 * config.yaml, holding the same three transferable knobs: model, language,
 * vocabulary.
 */
class Settings(context: Context) {

    private val prefs: SharedPreferences =
        context.getSharedPreferences("voiceflow", Context.MODE_PRIVATE)

    /** Model id from [ModelManager.MODELS]. */
    var modelId: String
        get() = prefs.getString("model", ModelManager.DEFAULT.id) ?: ModelManager.DEFAULT.id
        set(value) = prefs.edit().putString("model", value).apply()

    /**
     * ISO 639-1 code or "auto". Defaults to the device language — the person
     * most likely dictates in the language their phone speaks.
     */
    var language: String
        get() = prefs.getString("language", null) ?: Locale.getDefault().language.ifBlank { "auto" }
        set(value) = prefs.edit().putString("language", value).apply()

    /**
     * Custom vocabulary, one term per line. Joined into whisper's
     * initial_prompt — it biases decoding toward these words, same mechanism
     * as the desktop `model.vocabulary`.
     */
    var vocabulary: String
        get() = prefs.getString("vocabulary", "") ?: ""
        set(value) = prefs.edit().putString("vocabulary", value).apply()

    val vocabularyPrompt: String?
        get() = vocabulary.lines()
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .takeIf { it.isNotEmpty() }
            ?.joinToString(", ")
}
