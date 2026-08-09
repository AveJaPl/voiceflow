# Changelog

Platform tags: **[All]** · **[Linux]** · **[Windows]**

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
