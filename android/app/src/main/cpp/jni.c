// JNI bridge for voiceflow's Android keyboard.
//
// Deliberately tiny: init from a model file, one blocking full transcription,
// free. Adapted from whisper.cpp's whisper.android example, with the two
// things the example hardcodes made configurable: the language and the
// initial prompt (which carries the user's custom vocabulary, same trick as
// the desktop app's `model.vocabulary`).
#include <jni.h>
#include <android/log.h>
#include <stdlib.h>
#include <string.h>
#include "whisper.h"

#define TAG "voiceflow-jni"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, TAG, __VA_ARGS__)
#define UNUSED(x) (void)(x)

JNIEXPORT jlong JNICALL
Java_io_github_avejapl_voiceflow_whisper_WhisperLib_initContext(
        JNIEnv *env, jobject thiz, jstring model_path_str) {
    UNUSED(thiz);
    const char *model_path = (*env)->GetStringUTFChars(env, model_path_str, NULL);
    struct whisper_context_params cparams = whisper_context_default_params();
    struct whisper_context *context =
            whisper_init_from_file_with_params(model_path, cparams);
    (*env)->ReleaseStringUTFChars(env, model_path_str, model_path);
    return (jlong) context;
}

JNIEXPORT void JNICALL
Java_io_github_avejapl_voiceflow_whisper_WhisperLib_freeContext(
        JNIEnv *env, jobject thiz, jlong context_ptr) {
    UNUSED(env);
    UNUSED(thiz);
    whisper_free((struct whisper_context *) context_ptr);
}

// Blocking. Returns the concatenated segment texts (UTF-8), or NULL on failure.
JNIEXPORT jstring JNICALL
Java_io_github_avejapl_voiceflow_whisper_WhisperLib_fullTranscribe(
        JNIEnv *env, jobject thiz, jlong context_ptr, jint num_threads,
        jstring language_str, jstring prompt_str, jfloatArray audio_data) {
    UNUSED(thiz);
    struct whisper_context *context = (struct whisper_context *) context_ptr;
    if (context == NULL) {
        return NULL;
    }

    jfloat *audio = (*env)->GetFloatArrayElements(env, audio_data, NULL);
    const jsize audio_len = (*env)->GetArrayLength(env, audio_data);
    const char *language = (*env)->GetStringUTFChars(env, language_str, NULL);
    const char *prompt = prompt_str
            ? (*env)->GetStringUTFChars(env, prompt_str, NULL) : NULL;

    struct whisper_full_params params =
            whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    params.print_realtime   = false;
    params.print_progress   = false;
    params.print_timestamps = false;
    params.print_special    = false;
    params.translate        = false;
    // "auto" means language detection; whisper.h expects NULL or "auto".
    params.language         = (strcmp(language, "auto") == 0) ? "auto" : language;
    params.n_threads        = num_threads;
    params.no_context       = true;
    params.initial_prompt   = prompt;
    // Re-inject the vocabulary prompt into every decoder window, not just the
    // first — otherwise biasing fades out on longer dictations.
    params.carry_initial_prompt = (prompt != NULL);

    LOGI("transcribe: %d samples, lang=%s, threads=%d",
         (int) audio_len, language, (int) num_threads);

    jstring result = NULL;
    if (whisper_full(context, params, audio, audio_len) != 0) {
        LOGW("whisper_full failed");
    } else {
        const int n = whisper_full_n_segments(context);
        size_t total = 1;
        for (int i = 0; i < n; i++) {
            total += strlen(whisper_full_get_segment_text(context, i));
        }
        char *text = malloc(total);
        if (text != NULL) {
            text[0] = '\0';
            for (int i = 0; i < n; i++) {
                strcat(text, whisper_full_get_segment_text(context, i));
            }
            result = (*env)->NewStringUTF(env, text);
            free(text);
        }
    }

    (*env)->ReleaseFloatArrayElements(env, audio_data, audio, JNI_ABORT);
    (*env)->ReleaseStringUTFChars(env, language_str, language);
    if (prompt != NULL) {
        (*env)->ReleaseStringUTFChars(env, prompt_str, prompt);
    }
    return result;
}

JNIEXPORT jstring JNICALL
Java_io_github_avejapl_voiceflow_whisper_WhisperLib_getSystemInfo(
        JNIEnv *env, jobject thiz) {
    UNUSED(thiz);
    return (*env)->NewStringUTF(env, whisper_print_system_info());
}
