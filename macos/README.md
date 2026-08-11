# voiceflow — macOS

Native SwiftUI menu-bar app implementing the roadmap item [#3](https://github.com/AveJaPl/voiceflow/issues/3)
(daemon/transcriber/preview/vocabulary logic reimplemented natively per module,
matching the boundaries in the main README's "How it works" table).

## What works today

Feature parity with Linux, module by module. Anything not listed here is not
implemented on macOS yet.

| | |
|---|---|
| **Hold-to-talk** | Hold a modifier (right ⌥ by default), speak, release. Configurable: Fn/Globe, either ⌃, ⇧, ⌘. There is no press-to-toggle mode here — the Linux one exists because GNOME cannot report key release; macOS can, so holding is the native fit. |
| **Recognition** | whisper.cpp on-device for Polish (offline, no server), Apple's engine for English. Local-agreement partial commit, so text appears while you speak rather than after. |
| **Live typing** | Text goes into the focused window as you talk, via Accessibility. Applications that break under synthetic keystrokes (Electron, some IDEs) fall back to clipboard paste automatically, and the final pass always goes through the clipboard so the result is deterministic. |
| **Overlay** | A non-activating pill: waveform while listening, the result with a copy button when done. Draggable, and it remembers where you put it. It can never take focus — that is the one thing that would break dictation entirely. |
| **Cancel** | Escape during dictation drops everything: no text, no history entry. |
| **History** | Every dictation is stored in `history.jsonl`, the same format Linux and Windows use, including whether the text actually reached the target application. |
| **Window** | Przegląd, Historia, Statystyki, Słownik, Ustawienia — the same five pages as the Linux app, same layout and palette. Open with ⌘O from the menu bar. |
| **Statistics** | Totals, words per day, streak, 26-week activity calendar. Computed by `StatsLib`, a port of the shared Python implementation whose tests assert values taken from running that implementation. |
| **Vocabulary** | Proper nouns pushed into the whisper decoder prompt — takes effect immediately, no restart. |
| **Audio ducking** | Other applications are turned down while you dictate, restored afterwards. |
| **Microphone isolation** | Optional: swaps the system default input to a silent device (BlackHole) so a voice chat cannot hear the dictation, and restores it after. Needs BlackHole installed and Discord set to "Default" input. |
| **Discord Rich Presence** | Optional, shows that you are dictating. Local IPC only. |
| **Wspólny pokój** | Dołącz kodem w Ustawieniach. Kiedy ktoś inny w pokoju mówi, Twój skrót nie zaczyna nagrywać, a dźwięk na tym Macu ścisza się sam; Twoje dyktowania liczą się do rankingu sesji. Wysyłane są wyłącznie zdarzenia obecności i liczby — nagranie i tekst nigdy. Wyłączone, dopóki nie dołączysz. |
| **Remote microphone** | Optional: an iPhone can act as a hold-to-talk microphone over a relay. |

Not implemented: per-application volume rules (`duck_rules` on Linux) — macOS
exposes no per-app volume API, so ducking is all-or-nothing here.

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

There is no installer and no release artifact for macOS. You build it yourself,
because the app needs a code-signing identity tied to *your* Apple ID — nobody
can ship you a working binary without one.

### 0. Check this before anything else

`project.yml` sets `deploymentTarget: macOS "26.0"`. On an older system the
build fails immediately. Lowering that number has not been tried, so treat
macOS 26 as a hard requirement for now.

### 1. Prerequisites

```bash
xcode-select --install                 # or the full Xcode from the App Store
brew install whisper-cpp xcodegen
```

`whisper-cpp` is not optional: `WhisperSpeechEngine` links against Homebrew's
`libwhisper` directly (see `Core/VoiceFlow-Bridging-Header.h` for why, rather
than the official SPM package).

### 2. Generate the Xcode project

The `.xcodeproj` is **not** in git — it is generated, so that project settings
live in a reviewable `project.yml` instead of a binary blob:

```bash
cd macos
xcodegen generate
```

### 3. Signing — the step that trips everyone

`project.yml` carries a hardcoded `DEVELOPMENT_TEAM`, and it is the team of
whoever set the port up. On your Mac it will not resolve. Two ways out:

**In Xcode (simplest):**

```bash
open VoiceFlow.xcodeproj
```

Target *VoiceFlow* → *Signing & Capabilities* → tick *Automatically manage
signing* → pick your own team (a free personal team is enough). Then ⌘R.
Remember that `xcodegen generate` regenerates the project and overwrites this,
so either edit `project.yml` for good or repeat the step.

**From the command line:**

```bash
xcodebuild -project VoiceFlow.xcodeproj -scheme VoiceFlow build \
    DEVELOPMENT_TEAM=YOURTEAMID
xcodebuild -project VoiceFlow.xcodeproj -scheme VoiceFlow test \
    DEVELOPMENT_TEAM=YOURTEAMID
```

Ad-hoc signing (`CODE_SIGN_IDENTITY="-"`) builds, but do not use it: macOS keys
the Accessibility and Input Monitoring grants to the code signature, so every
rebuild changes the hash and the system silently drops the permissions the app
needs to type anywhere.

### 4. Intel Macs

`HEADER_SEARCH_PATHS` and `LIBRARY_SEARCH_PATHS` point at `/opt/homebrew`,
which is the Apple Silicon prefix. On Intel, Homebrew lives in `/usr/local` —
change both paths in `project.yml` (and in the test target, which repeats them).

### 5. First run

The app has no Dock icon by design (`LSUIElement`) — look for the microphone in
the menu bar. macOS will ask for **Microphone** and **Accessibility**
permissions; without Accessibility the app records but cannot type anywhere.
Open the window with **Otwórz voiceflow** (⌘O) from that menu.

Dictation history is written to
`~/Library/Application Support/VoiceFlow/history.jsonl`, in the same format
Linux and Windows use.

## Also included: remote microphone (phone → Mac) relay

`../relay/` is a small WebSocket relay (Node, pass-through only, never logs
audio) that lets the iOS app act as a remote hold-to-talk microphone for this
Mac app over the internet (not just local WiFi) — `Core/RemoteMicClient.swift`
on this side. Optional, off by default, requires pairing through the relay's
`/pair` endpoint.
