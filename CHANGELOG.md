# Changelog

Platform tags: **[All]** · **[Linux]** · **[Windows]** · **[Android]** · **[Web]**

## 0.3.1 — 2026-08-10

- **[Windows]** Fixed: the paste chord defaulted to `ctrl+shift+v`, which most
  native Windows applications ignore — dictation completed and delivered
  nothing. The default is now `ctrl+v` per platform, and modifiers the user is
  still holding from the hotkey are released before the chord is sent.
- **[Windows]** Fixed: GPU transcription failed on the first real dictation with
  `cublas64_12.dll is not found`. The cuBLAS/cuDNN wheels are now installed and
  preloaded on Windows too, as they already were on Linux.
- **[All]** Fixed: model warmup ran with the VAD on, so it discarded its own
  silent test clip before reaching the encoder — a GPU that could not encode
  passed warmup and only failed later, long past the CPU fallback. Warmup now
  exercises the encoder.
- **[Windows]** Fixed: every clipboard call truncated 64-bit handles to 32 bits
  (missing ctypes `restype`), which could corrupt memory or crash the daemon.
- **[Windows]** Fixed: audio ducking failed on every recording with
  `CoInitialize has not been called`, and restored volumes across COM
  apartments. Volumes are now remembered per process id and re-resolved.
- **[Windows]** Fixed: holding the hotkey autorepeated and toggled recording
  many times a second (`MOD_NOREPEAT`).
- **[Windows]** `voiceflow status`, `toggle`, `start`, `stop`, `cancel`,
  `last --copy` and the new `quit` now work, over a loopback control channel
  with a token file. Two daemons can no longer run at once.
- **[Windows]** Errors now raise a toast. Previously the daemon ran with no
  console and reported failures nowhere the user would look.
- **[Windows]** The installer stops a running copy before updating, launches via
  the venv's `pythonw.exe` instead of relying on `uv` being on `PATH`, verifies
  the install, and starts the daemon immediately.
- **[Windows]** The generated `config.yaml` is platform-appropriate: correct
  paste chord, real paths, a documented `hotkey` section, and no PipeWire-only
  advice.

## 0.3.0 — 2026-08-09

- **[Linux]** Fixed: a voice chat could stay quiet forever after dictation if its
  stream vanished mid-recording (WirePlumber persisted the ducked volume per app
  name). Restores now fall back to the application name and retry when the
  stream returns.
- **[Web]** The landing page grew: bilingual (/en, /pl), animated demos of the
  Linux flow and the Android keyboard, a speech-vs-typing chart, privacy pages.
- **[Web]** Landing page at [voiceflow.pbdevs.com](https://voiceflow.pbdevs.com):
  features, per-OS install commands, platform roadmap. Self-hosted, privacy-friendly
  analytics (Umami) — no cookies, no third parties.
- **[Android]** Early alpha of the voice keyboard (IME) in `android/`: on-device
  whisper.cpp (arm64 + emulator), model download in-app (tiny/base/small q5_1),
  language + custom vocabulary settings, monochrome dictation panel with
  backspace/space/enter. Not yet packaged; build from source ([android/README.md](android/README.md)).

## 0.2.1 — 2026-08-09

- **[All]** Update check: voiceflow now checks GitHub once a day for a newer
  release (single anonymous request; disable with `updates.check: false`).
  The desktop app shows an update button; `voiceflow update` checks from the CLI.
- **[All]** This changelog, with per-platform tags.

## 0.2.0 — 2026-08-09

- **[Linux]** Desktop control center (GTK4/libadwaita): sidebar, live dashboard,
  searchable history, statistics (14-day chart, GitHub-style activity calendar),
  per-app volume sliders, vocabulary editor, Discord section.
  Requires `python3-gi-cairo`.
- **[All]** Dictation history: local log; `voiceflow last --copy` recovers text
  pasted into the wrong window. Powers the statistics.
- **[All]** Per-app ducking rules with a default for unknown apps.
- **[Linux]** Automatic mute of voice-chat microphone streams while dictating.
- **[All]** Discord Rich Presence ("dictating" activity with a timer).
- **[Windows]** Beta port: in-daemon global hotkey (Ctrl+Shift+Space), PortAudio
  recording, clipboard+SendInput injection, no-focus overlay, Core Audio ducking,
  Start Menu entry with icon, silent background launch, double-clickable
  installer. GPU needs system cuDNN (CPU fallback otherwise); per-app microphone
  mute is not possible on Windows.

## 0.1.0 — 2026-08-09

- **[Linux]** First release: hotkey dictation with faster-whisper held warm in
  VRAM, live on-screen preview, clipboard-safe injection for any language,
  custom decoding vocabulary, voice-chat mute/duck, hardware-free test suite.
