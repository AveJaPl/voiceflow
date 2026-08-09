# voiceflow for Android (early alpha)

A **voice keyboard** (IME): instead of porting the desktop daemon, dictation
becomes a system keyboard with one big microphone key — so it works in every
app, which is exactly what the desktop hotkey does. Tracking issue:
[#6](https://github.com/AveJaPl/voiceflow/issues/6).

Transcription is **on-device**: [whisper.cpp](https://github.com/ggml-org/whisper.cpp)
(pinned as a submodule in `third_party/`) built for arm64 + x86_64, ggml
q5_1 models downloaded on first run into the app's private storage. No audio
leaves the phone; the only network access is the model download.

## Layout

```
android/
├── third_party/whisper.cpp    git submodule, pinned to a release tag
└── app/
    └── src/main/
        ├── cpp/               CMake + JNI bridge (init / transcribe / free)
        └── java/io/github/avejapl/voiceflow/
            ├── ime/           VoiceflowIme (InputMethodService) + KeyboardView
            ├── whisper/       Kotlin wrapper, single-threaded native executor
            ├── audio/         16 kHz recorder (48 kHz fallback) + WAV reader
            ├── model/         model catalog + resumable-ish downloader
            ├── Settings.kt    model / language / vocabulary (SharedPreferences)
            └── MainActivity   one-screen setup: enable IME, mic, model
```

## Build

```bash
git submodule update --init android/third_party/whisper.cpp
cd android
JAVA_HOME=<jdk17> ./gradlew assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

Requirements: JDK 17, Android SDK 35, NDK 28, CMake 3.22. `local.properties`
with `sdk.dir=` is created by Android Studio or by hand.

## Trying it on the emulator

The emulator has no real microphone, so debug builds expose a broadcast that
runs the full pipeline (WAV → whisper → commit into the focused field):

```bash
adb shell ime enable io.github.avejapl.voiceflow/.ime.VoiceflowIme
adb shell ime set    io.github.avejapl.voiceflow/.ime.VoiceflowIme
adb push sample16k.wav /data/local/tmp/sample.wav
adb shell am broadcast -a io.github.avejapl.voiceflow.DEBUG_TRANSCRIBE \
    --es path /data/local/tmp/sample.wav
```

## Design decisions

- **CPU-only inference** (`GGML_USE_CPU`): mobile GPU delegates are per-vendor
  minefields; tiny/base/small are realtime-ish on phone CPUs.
- **Default model `small-q5_1`** (190 MB): the smallest model with usable
  Polish. `tiny`/`base` remain selectable for low-end devices.
- **Vocabulary = `initial_prompt` with `carry_initial_prompt`** — the same
  bias-not-rewrite mechanism as the desktop `model.vocabulary`.
- **Recording stops in `onFinishInputView`** — on Android 12+ a hidden IME
  receives silence, not an error, so the lifecycle is the only honest stop
  signal.
- The keyboard ships **no full QWERTY**: it is a dictation panel with
  backspace/space/enter and a switch-back key. Your regular keyboard stays
  one globe-tap away.

## Status / not done yet

- [ ] Live preview while speaking (chunked decode → `setComposingText`)
- [ ] Streaming/VAD instead of tap-to-stop
- [ ] Punctuation commands, auto-capitalization options
- [ ] Password fields: suppress dictation UI
- [ ] Play Store / F-Droid packaging (issue #6)
