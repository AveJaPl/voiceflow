# voiceflow — macOS

Native SwiftUI menu-bar app implementing the roadmap item [#3](https://github.com/AveJaPl/voiceflow/issues/3)
(daemon/transcriber/preview/vocabulary logic reimplemented natively per module,
matching the boundaries in the main README's "How it works" table).

## Modules (mirrors the main project's `recorder`/`transcriber`/`injector`/`overlay`/`micmute` split)

| module | this port |
|---|---|
| `recorder` | `Core/AudioCapture.swift` — AVFoundation |
| `transcriber` | `Core/AppleSpeechEngine.swift` (Apple SFSpeechRecognizer, server-side for Polish) + `Core/WhisperSpeechEngine.swift` (whisper.cpp, on-device, default — see rationale below) |
| `injector` | `Injection/TextInjector.swift` — ladder: Accessibility → CGEvent unicode → clipboard+⌘V |
| `overlay` | `UI/PillWindow.swift` — borderless non-activating `NSWindow` |
| `micmute` | not implemented — macOS has no per-app volume API (issue #3 already flags this: "likely ships disabled") |

## Why whisper.cpp instead of the Apple server path by default

Apple's `SFSpeechRecognizer` is the only Apple-native path for Polish on macOS
(the new `SpeechAnalyzer`/`SpeechTranscriber` don't support `pl-PL`), and it's
**server-side only** — no on-device option for Polish on this platform. On
2026-08-10 it silently hung system-wide (zero result, zero error, zero network
attempt) with no way to recover short of a reboot. `WhisperSpeechEngine`
(model `ggml-base`, local, offline) is now the default for Polish — same
whisper.cpp core the project already uses elsewhere, wired into a persistent
streaming session with local-agreement partial-commit logic. English stays on
Apple's engine (on-device there, no known issues).

## Build

```bash
cd macos
xcodegen generate
xcodebuild -project VoiceFlow.xcodeproj -scheme VoiceFlow build
xcodebuild -project VoiceFlow.xcodeproj -scheme VoiceFlow test
```

Requires `brew install whisper-cpp xcodegen` and a paid Apple Developer account
(or free personal team) for code signing — Accessibility/Input Monitoring
permissions require a stable signing identity, not ad-hoc.

## Also included: remote microphone (phone → Mac) relay

`../relay/` is a small WebSocket relay (Node, pass-through only, never logs
audio) that lets the iOS app act as a remote hold-to-talk microphone for this
Mac app over the internet (not just local WiFi) — `Core/RemoteMicClient.swift`
on this side. Optional, off by default, requires pairing through the relay's
`/pair` endpoint.
