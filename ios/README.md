# voiceflow — iOS

Implements roadmap item [#7](https://github.com/AveJaPl/voiceflow/issues/7) —
custom keyboard extension + container app, per the architecture sketch in
that issue.

## Structure

- `VoiceFlowApp/` — container app: onboarding (Wispr-Flow-style guided setup,
  ends with a live in-app dictation test), history, settings, and the
  `voiceflow://dictate` handoff screen (see below).
- `VoiceFlowKeyboard/` — the keyboard extension: a minimal mic button, no
  QWERTY layer.
- `Shared/` — `AppGroup.swift` (shared UserDefaults), `TextDiffer.swift`
  (partial-transcript reconciliation, same algorithm as `../macos`),
  `PendingInsert.swift`.

## Confirmed on a physical iPhone 16 Pro (iOS 27), not assumed

- `SFSpeechRecognizer(locale: pl-PL).supportsOnDeviceRecognition == true` —
  Polish dictation runs fully on-device, no network, no Parakeet/whisper.cpp
  needed on iOS.
- `AVAudioEngine.start()` **fails inside the keyboard extension itself**
  even with Full Access granted (`com.apple.coreaudio.avfaudio` error
  2003329396 / `'what'`) — this matches the issue's own hint that a keyboard
  extension has a ~60-80 MB memory ceiling and is sandboxed; empirically the
  sandbox blocks live microphone capture entirely, not just heavy models.

## Consequence: the container-app handoff pattern (same one Wispr Flow uses)

The keyboard cannot record. Tapping its mic button calls
`extensionContext?.open(url: "voiceflow://dictate")`, which requires Full
Access but is standard extension API, not a workaround. The container app
opens already recording, writes the final transcript to the App Group with a
timestamp, and shows a "swipe back to your previous app" screen — this is
the same UX Wispr Flow's own docs describe ("Apple requires Flow to briefly
switch apps to activate the microphone"), not something invented for this
port. On return, the keyboard's `viewWillAppear` finds a fresh (<60s)
pending transcript and inserts it via `textDocumentProxy` automatically —
no extra tap needed.

## Build

```bash
cd ios
xcodegen generate
xcodebuild -project VoiceFlowIOS.xcodeproj -scheme VoiceFlowApp \
  -destination 'generic/platform=iOS' -allowProvisioningUpdates build
xcodebuild -project VoiceFlowIOS.xcodeproj -scheme VoiceFlowApp \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test
```

Bundle ids: `io.github.avejapl.voiceflow.ios` (container),
`io.github.avejapl.voiceflow.ios.keyboard` (extension), App Group
`group.io.github.avejapl.voiceflow.ios`.
