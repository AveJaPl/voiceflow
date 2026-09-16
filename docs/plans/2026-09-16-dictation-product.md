# VoiceFlow: focused dictation release

Scope: local Mac/iPhone dictation, Polish/English, model choice, local vocabulary,
voice keyboard start/stop with manual or automatic insertion, direct downloads.
No new room/account features. Preserve existing user data.

Design: charcoal #131316, white waveform, system typography for the Mac pill;
stable 204×54 recording panel with no material blur or geometry animation.
The meter updates at 30 Hz independently from recognition, with fast attack,
soft compression and separate bar motion. Silence remains visibly quiet.
The iPhone keyboard reuses this waveform and labels start/stop explicitly.

Implementation and verification:
- Fix Fn/Fn+Z arbitration and unmatched key releases with deterministic tests.
- Decouple Mac audio metering from ASR; render synthetic quiet/normal/loud states.
- Keep microphone in the iOS containing app; App Group session commands/status
  let the keyboard stop a user-started background recording and receive text.
  No silent microphone activation or fabricated recording animation.
- Add insertion preference, local vocabulary and language selection; local history.
- Build both apps and run hardware-free tests. Do not record speech, activate a
  desktop pill, restart the installed app, or open foreground simulator windows.
- Prepare signed releases/ASC metadata and verify landing links. Store approval
  and physical microphone/keyboard handoff remain separate release gates.

References:
- https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/CustomKeyboard.html
- https://docs.wisprflow.ai/articles/7453988911-set-up-the-flow-keyboard-on-iphone

Apple does not grant the keyboard extension microphone access. The containing
app must start recording; the OS can require switching to it and returning.
