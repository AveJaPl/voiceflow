# Changelog

Platform tags: **[All]** · **[Linux]** · **[Windows]** · **[Android]** · **[Web]**

## Unreleased

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
