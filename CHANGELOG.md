# Changelog

Platform tags: **[All]** · **[Linux]** · **[Windows]** · **[Android]** · **[Web]**

## Unreleased

- **[macOS]** Fixed: a second dictation carried the first one with it — the text
  was pasted again and both landed in one history note. The speech engines kept
  accumulating their transcript for the lifetime of the process, and the session
  tried to subtract the earlier part by comparing a text prefix. Whisper revises
  words it has already committed, so the prefix stopped matching and that code
  deliberately fell back to taking everything. Both engines now start each
  utterance with an empty transcript (the loaded model stays, which is what
  `prewarm` is actually for), and the prefix arithmetic is gone.
- **[macOS]** Fixed: after any error the state machine stayed in `error` forever.
  `beginUtterance` only accepts `idle`/`done`, so every later press of the
  shortcut was silently ignored — no pill, no recording, no explanation. A failed
  `prewarm` at launch disabled dictation until the app was restarted. An error is
  now a message, not a state to get stuck in.
- **[macOS]** A dictation that recognised nothing no longer parks an empty result
  card on screen for six seconds.
- **[macOS]** Visual tokens (`UI/Theme.swift`) copied verbatim from the Linux
  application's stylesheet, so the three platforms can converge on one look
  instead of drifting per platform.

- **[All]** Changed, and it needs a config edit: ducking is now a **multiplier**
  of each app's own volume instead of an absolute target, and `mute_apps.duck_volume`
  is renamed to `mute_apps.duck_to`. `0.6` means "leave 60% of wherever the slider
  already is". The old setting silenced quiet listeners and barely touched loud
  ones, because it ignored the level the app was already playing at — and because
  the value lands on the volume slider's cubic curve, an innocent-looking `0.29`
  was 2.4% of full amplitude, i.e. inaudible. The old key is ignored with a
  warning rather than reinterpreted; the numbers look the same but no longer mean
  the same thing.
- **[Linux]** The on-screen card can be dragged anywhere with the mouse and stays
  where it was put, across dictations and restarts. Double-click returns it to the
  bottom centre. A position on a monitor that no longer exists is discarded rather
  than leaving the card invisible.
- **[Linux]** "No speech detected" is shown on the card itself — a shorter,
  self-closing version of it — instead of a desktop notification that outlived
  its usefulness in the tray.
- **[Linux]** The dictation shortcut can be changed in the desktop app. It is
  written straight into GNOME's own shortcut store, and a candidate key is checked
  against every shortcut the desktop already has: taking one over now asks first
  and names what it would collide with.
- **[Linux]** The tray label dropped "słów" for a 💬 emoji, and its dropdown now
  shows two bar charts — today by hour, and the last 14 days — alongside the
  existing week/month/year summary.
- **[Windows]** The microphone half of `mute_apps` now works, so dictating no
  longer broadcasts the prompt to everyone on the call. While recording, the
  configured applications' capture sessions are muted and all playback is
  ducked; both are restored exactly afterwards, and a microphone the user muted
  themselves is never touched. This shipped as a documented no-op on the claim
  that Windows has no per-application capture mute. It does: every application
  recording through WASAPI owns a capture session with its own mute flag.
  Applications on the legacy MME/DirectSound paths remain invisible.
- **[Windows]** Restores no longer follow the process id alone. Windows persists
  an application's mixer state per application, so a session that died while
  voiceflow held it ducked — or muted — left that app quiet, or the user silent
  on their next call, permanently and with nothing to explain it. A restore that
  finds no live session now falls back to any newer session of the same
  executable, and whatever still cannot be reached is retried before the next
  recording is ducked. The Linux backend has carried this repair for a while;
  the Windows one now matches it.
- **[Windows]** Fixed a crash that took the whole process down with an access
  violation raised inside the garbage collector, pointing at whatever unrelated
  line happened to allocate at the time. Core Audio work ran on whichever thread
  called in, each opening and closing its own single-threaded COM apartment,
  while pycaw's session objects survive in reference cycles until the collector
  runs — by which time the apartment that owned them, or the thread itself, was
  gone, and releasing the pointer was illegal. All Core Audio calls now go
  through one immortal daemon thread in a multi-threaded apartment, where a late
  release from any thread is legal.
- **[All]** The daemon accepts an injectable `micmuter`, like every other
  collaborator. Without it, running the test suite drove the real Core Audio
  stack: the developer's microphone genuinely muted and their music genuinely
  ducked, mid-test.
- **[Windows]** Settings can edit which applications get their microphone muted,
  and the detected-applications list marks what is recording (🎤) as well as
  what is playing (●). The list existed but the setting behind it did not.

- **[Windows]** The shortcut is now recorded by pressing it. The settings field
  installs a low-level keyboard hook while recording, so it captures chords the
  shell would otherwise eat — `Win+Alt+Space` is bindable, and pressing Win does
  not open the Start Menu. Escape cancels, and an abandoned recording releases
  the keyboard by itself after eight seconds.
- **[Windows]** A recorded chord is checked against Windows before anything is
  saved: the field says *wolny* or *zajęty przez inną aplikację* while you are
  still choosing, instead of the daemon discovering the conflict after a restart
  and a four-second model reload. The daemon's own shortcut is recognised rather
  than reported as taken.
- **[Windows]** Fixed: the dashboard reported the *configured* hotkey, so a
  shortcut Windows had refused to register still appeared as "wciśnij, mów" —
  the UI insisted the feature worked while nothing happened. The daemon now
  reports whether registration actually succeeded, and the dashboard says so.
- **[Windows]** `f13`–`f24` are accepted in `hotkey.binding`. They are on no
  physical keyboard, which makes them the one class of shortcut nothing else
  can claim: remap Caps Lock to F13 and dictation is a single keypress.

## 0.4.0 — 2026-08-10

- **[Windows]** Added the desktop window. All five pages the Linux application
  has — przegląd, historia, statystyki, ustawienia, słownik — with daemon
  start/stop, searchable history, charts, the full `config.yaml` editor and the
  vocabulary. **voiceflow** in the Start Menu now opens it instead of silently
  re-launching an already-running daemon.
- **[Windows]** The window is Qt, not a port of the GTK code: PyGObject
  publishes no Windows wheel at all, so libadwaita is not reachable there. The
  daemon underneath is unchanged, and the window edits the same `config.yaml`
  and speaks the same control channel as the command line.
- **[All]** Config edits are read-modify-write under a lock. Two pages saving
  from their own threads previously raced, and whichever wrote first lost its
  changes; keys the window does not know about are preserved either way.

## 0.3.2 — 2026-08-10

- **[Windows]** Fixed: clicking the Start Menu entry while voiceflow was already
  running did nothing at all — the second instance correctly refused to start,
  but under `pythonw.exe` it had no console to say so, which reads as "the app
  won't open". It now reports that voiceflow is running and repeats the hotkey.
  There is no window to open on Windows by design; this is the feedback that
  replaces one.
- **[Windows]** Fixed: notifications sent immediately before the process exited
  were never drawn. The toast is delivered on a daemon thread, so exiting killed
  it — losing exactly the message that explained the failure. Callers that are
  about to exit now flush.

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
- **[Linux]** GNOME top-bar indicator for dictation statistics: shows today's
  spoken time and word count in the bar label; click to reveal this week, month,
  and year totals in a dropdown menu. Requires `gir1.2-ayatanaappindicator3-0.1`
  (installed automatically by install.sh).
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
