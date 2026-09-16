# VoiceFlow for iPhone

Local WhisperKit dictation with Polish/English detection, model selection,
custom vocabulary and local history. No sign-in is required. The first launch
downloads a device-appropriate model; dictation waits for that model to be ready.

The voice keyboard replaces the system keyboard with a start/stop panel and
an audio-driven waveform shared with the Mac pill. iOS does not allow microphone
access inside keyboard extensions. Recording starts in the containing app; the
user returns with the system gesture. UIBackgroundModes audio keeps that active
recording running. The keyboard sends a session-scoped stop request through the
App Group and reads atomic status snapshots. GPU computation is disabled in the
WhisperKit model configuration for background recognition.

Automatic insertion is permitted only for a fresh result, in the original text
field, and only once. Otherwise the keyboard offers manual insertion. Closing
the app's dictation sheet explicitly cancels recording. Stale status stops the
recording animation instead of pretending the microphone is still active.

Setup: enable VoiceFlow in iOS Keyboard settings and grant Full Access for App
Group communication. Grant Microphone access in the main app. Opening the app
from the keyboard uses SwiftUI's public openURL action; behavior must be checked
on the target iOS version. A manual-open hint remains when the OS refuses.

Build: `cd ios && xcodegen generate`; use the VoiceFlowApp scheme.
Release: `tools/release-ios.sh --no-upload`, then upload the reviewed IPA.
Debug-only launch arguments `-vfSkipOnboarding YES -vfSkipModelPreparation YES`
allow UI checks without audio or downloading a model. They are disabled in Release.

Verification boundary: simulator logic/UI checks do not establish physical
microphone capture, background inference latency, keyboard handoff or mixed-language
accuracy. Those require a real-device recording test before App Store submission.
