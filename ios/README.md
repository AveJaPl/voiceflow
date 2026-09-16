# VoiceFlow — iOS

Container app and custom keyboard for `io.github.avejapl.voiceflow.ios`.
Minimum iOS: 17. iPhone only (`TARGETED_DEVICE_FAMILY: 1`).

## Current flow

The app has Keyboard, History, Rooms and Settings tabs. WhisperKit performs
local transcription with a model selected for the device. While the model is
unavailable, Apple speech recognition is used with on-device processing required.
The UI checks in the simulator do not establish transcription quality on hardware.

The keyboard cannot record audio. It asks the system to open `voiceflow://dictate`;
this is not a supported guarantee for keyboard extensions. If the system rejects
the request, the keyboard tells the user to open VoiceFlow and select “Dyktuj teraz”.
The old responder-chain `openURL:` fallback was removed because it fails on modern
iOS and bypasses the extension API restriction. See Apple's explanation:
https://developer.apple.com/forums/thread/764570

After dictation, the app stores text in the shared App Group. On returning to the
keyboard, a fresh result (less than 60 seconds old) is inserted once. The user must
return to the original app manually. Secure text fields and apps that disallow
third-party keyboards do not support this extension.

History in the History tab requires an account. Signed-in dictations are also
uploaded as text to the account service; audio remains local. Rooms reads the live
ranking and can change the room's blocking mode. The current iOS app has no remote
transcription-server setting or remote Mac control tab.

## Build and test

```sh
cd ios
xcodegen generate
xcodebuild -project VoiceFlowIOS.xcodeproj -scheme VoiceFlowApp \
  -destination 'generic/platform=iOS' -allowProvisioningUpdates build
xcodebuild -project VoiceFlowIOS.xcodeproj -scheme VoiceFlowApp \
  -destination 'platform=iOS Simulator,name=iPhone 16e' test
```

For silent UI checks in a Debug build, launch with
`-vfSkipOnboarding YES -vfSkipModelPreparation YES`. These flags are disabled
in Release. Do not tap “Dyktuj teraz” during checks that must not use the microphone.
The WhisperKit fixture test is skipped in the simulator; it requires a device.

Bundle IDs: `io.github.avejapl.voiceflow.ios` and
`io.github.avejapl.voiceflow.ios.keyboard`. App Group:
`group.io.github.avejapl.voiceflow.ios`.

## Distribution status

On 16 September 2026, App Store Connect confirmed `0.6.0 (1)` as `VALID`, but
TestFlight was blocked by `MISSING_EXPORT_COMPLIANCE` and had no tester groups.
The App Store record was `1.0`, `PREPARE_FOR_SUBMISSION`, with empty metadata.
See `../docs/plans/2026-09-16-apple-audit.md` for verification and remaining work.
