# Changelog

Platform tags: **[All]** · **[Linux]** · **[Windows]** · **[Android]** · **[Web]**

## 0.5.0 — 2026-08-14

- **[Windows]** Music stays quiet for the whole dictation. Ducking used to be a
  single pass over the audio sessions that existed when the hotkey was pressed,
  and a session is born at the application's own volume — so when Spotify moved
  to the next track mid-sentence, the new song came back at full blast, and
  anything that only started playing after the hotkey was never turned down at
  all. The ducked applications are now re-checked every half second until the
  recording ends: a stream found above its target is pushed back down, a new
  application is ducked like any other, and the level restored afterwards is
  still the one the user had set before dictating.
- **[All]** Only one daemon can start, including during the half-minute the
  first one spends loading its model. The old guard asked whether anything was
  answering the control channel — but that channel is opened at the *end* of
  startup, so for thirty seconds voiceflow looked exactly like nothing was
  running. Seven daemons were found doing this at once: each loaded its own copy
  of the model, which made every one of them slower to start, which kept the
  window reporting that nothing was running, which invited another click. Only
  the first held the dictation shortcut, so the other six reported it as taken
  by "another application" — it was, by voiceflow. A daemon now claims an
  OS-level lock before it touches anything at all (no model, no microphone, no
  room), and the operating system drops that claim when the process dies, so a
  crash cannot leave voiceflow locked out. The desktop window also stops
  offering to start a second one and says **Demon się uruchamia** while it waits.
- **[All]** A long dictation no longer means a long wait. What has already been
  said is transcribed during the pauses, so after the hotkey only the stretch
  since the last pause is left to do — measured on an i7-1260P, 50 s of Polish
  went from 24.7 s of waiting to 10.1 s, and the text came out the same.
  The cut is made in silence the speaker meant (0.7 s, never a breath) and keeps
  a margin past the last word, because at 0.15 s a rehearsal cut "zbliżającym"
  into "zbli za jacym" — the VAD ends a word where its energy stops, which is
  slightly before the word does. Nothing is committed below 25 s of audio, and
  that number is Whisper's, not a preference: its encoder always processes a
  30-second window, so decoding 6 s costs 7.6 s while decoding 29 s costs 11.8 s.
  Committing in small pieces does not divide the work between the pauses, it
  multiplies it — the first version of this shortened nothing and made a 29 s
  dictation wait 16 s instead of 11.8 s. Shorter dictations are transcribed in
  one pass exactly as before; `incremental.enabled: false` restores the old
  behaviour outright.
- **[All]** Transcription on the CPU uses the whole processor. CTranslate2 takes
  four threads regardless of what the machine has, which on a laptop left two
  thirds of it idle while its owner waited for their text; the model is now given
  one thread per physical core (hyperthreads excluded — they measured slower on a
  memory-bound int8 matrix multiply). Measured on an i7-1260P, 20 s of Polish:
  12.2 s → 9.8 s. `model.cpu_threads` overrides the count for anyone who wants
  to leave the machine room to breathe; 0, the default, means "read the machine".
- **[Windows]** Dictation lands in the focused window again. The preview card is
  marked `WS_EX_NOACTIVATE` precisely so it cannot take the focus, but tkinter
  takes the foreground the moment it *realizes* its window — before there is a
  handle to put that style on. So from the first word spoken the card was the
  window in front, and the paste chord went to it instead of the terminal or
  editor the user was dictating into: the text reached the clipboard, the
  history recorded it as injected, and nothing appeared anywhere. The card now
  remembers which window was in front before it starts and hands the foreground
  straight back — its own theft and nothing else, so a window the user chose in
  the meantime is left alone.
- **[Windows]** No console window any more — not at login, not when the Start
  Menu icon is clicked. The daemon and the desktop window are started through
  `pythonw.exe` precisely so that none exists, but uv builds
  `.venv\Scripts\pythonw.exe` as a trampoline that re-launches the *console*
  interpreter, and a console program whose parent has no console is given a
  brand-new console window of its own: a black window of log lines over the
  user's work, with the desktop window opening behind it. Both installers now
  replace that trampoline with the real `pythonw.exe`, so the window is never
  created; `python.exe` keeps its console, because the command line needs one.
  Copies installed before this fix are covered too — the daemon and the window
  free a console of their own at startup, while a console shared with a shell
  (`voiceflow daemon` typed into a terminal) is left alone, log output included.
- **[Windows]** `windows\install-local.ps1` installs the working copy as the
  installed one, keeping the environment and the downloaded model, so the Start
  Menu icon opens the application being worked on instead of the last release.
- **[Windows]** The desktop window is now the same window as on Linux, not a
  Qt-flavoured relative of it. It was two pages behind and looked like a
  different product: red accent buttons where GTK has white ones, no Pokój and
  no Sesje tab at all, ducking edited as a comma-separated list of executables
  in a text box, and no way to see which application was holding the microphone.
  Ported across, group for group: the sidebar with its brand mark and selection
  indicator, the page title in the window bar, one shared **Niezapisane zmiany**
  bar with Cofnij/Zastosuj instead of per-page save buttons, and all seven pages
  — Przegląd, Historia, Statystyki, Pokój, Sesje, Słownik, Ustawienia.
- **[Windows]** Ducking and microphone muting are edited the way they are on
  Linux: every detected application is a row with its own volume slider ("60%
  obecnej", "100% · nie ściszaj"), applications holding the microphone right now
  are switches marked *nagrywa teraz*, and a rule for an application that is no
  longer running stays visible as *zapamiętana · niedziałająca* with a button to
  forget it. Moving the default slider moves every application that has no rule
  of its own, and leaves the ones that do alone.
- **[Windows]** Rooms are reachable without a terminal, including discovery on
  the local network. Linux announces a room over Avahi; Windows has no Avahi, so
  it speaks the same mDNS protocol through `zeroconf` — the wire format is
  identical, so a room advertised from a Linux laptop appears in the Windows
  window and the other way round. Creating, joining and leaving now restart the
  daemon themselves, because it reads its configuration only at startup.
- **[Windows]** The icons the GTK application takes from the desktop icon theme
  are drawn as vector strokes instead, since Windows has no icon theme to borrow
  from: sharp at any scale, and the same colour as the text beside them.

- **[All]** Shared dictation rooms. Two people in one room stop talking over each
  other: whoever is speaking blocks the others, and their speaking quietens audio
  on every machine in the room, not just their own. Sessions are measured — who
  dictated how much — and a page shows the standings live, for a tablet next to
  the desk. Joining is opt-in and off by default: it is the one feature that
  sends anything off the machine, and even then only presence events and counts.
  The recording and the transcribed text never leave.
- **[macOS]** Rooms work here too: join from Settings, the shortcut respects
  somebody else speaking, and remote speech ducks this Mac's audio through the
  same ducker the local shortcut uses.

- **[Web]** The landing page now deploys through the same GitHub App every other
  application on that Coolify server uses, instead of being the one resource on a
  "Public GitHub" source with a hand-wired webhook. Push-to-deploy worked before
  this change and still works; what changes is that the webhook is managed by the
  App rather than by hand, so it cannot quietly rot, and the repository could go
  private without the deploy breaking.

- **[macOS]** Added the main window, built to match the Linux application:
  sidebar navigation and the same five pages — Przegląd, Historia, Statystyki,
  Słownik, Ustawienia — with the same headings, the same dark monochrome palette
  and the same layout of cards. Until now the Mac was a menu-bar app with a
  settings sheet and a separate notes list, and had no statistics at all. Open it
  from the menu bar with **Otwórz voiceflow** (⌘O).
- **[macOS]** `StatsLib` ports the shared statistics to Swift — totals, daily
  series, streak, quantile activity levels, and the Polish number and duration
  formatting. Its tests assert values produced by running the Python
  implementation, so the two cannot drift without a test failing.
- **[macOS]** Settings keep their existing controls for now. They carry real
  behaviour — remote-microphone pairing, Discord shortcut capture — that is not
  worth rewriting blind; they now live inside the new window instead of a
  separate sheet.

- **[macOS]** Dictation history now uses the same format as Linux and Windows:
  one JSON object per line, same keys, in `history.jsonl`. The Mac kept its own
  `notes.json` with a different schema that carried no word or character counts,
  so statistics could not be computed there at all; it also had no size limit and
  rewrote the entire file after every dictation. Existing notes are converted on
  first launch and the old file is left in place as a backup. macOS adds
  `id`, `raw_text` and `target_bundle_id` on top of the shared keys, which the
  shared reader ignores. Whether the text actually reached the target
  application is recorded too, as it already was elsewhere — that flag is what
  makes history a recovery path rather than a log.

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
