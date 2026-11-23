# README demo (generated)

A 13-second [Remotion](https://www.remotion.dev) composition: `Super+G`, a dictated
request, the live preview card, `Super+G` again, and the text pasted into a Claude Code
session on GNOME. It produces `docs/assets/demo.mp4` (with voice) and
`docs/assets/demo.gif` (silent, for the README).

What is faithful and what is drawn:

- The overlay card copies `scripts/voiceflow-overlay.py`: colours, border, inset
  highlight, breathing dot, dimmed dot during the final pass, five-line height,
  bottom-centre position. It is drawn larger than on a real 1080p screen so it stays
  readable at 720p.
- The preview text at each one-second tick is exactly what faster-whisper
  (`large-v3-turbo`, same model as the app) places before that moment in
  `public/voice.mp3`. Timings live in `src/words.json`, made by `words.py`.
- The voice is synthetic (ElevenLabs). The desktop, terminal and the agent's reply
  are illustrations.
- The idle placeholders the real card shows ("Słucham…", "Przetwarzam…") are left
  out until the UI is translated (#5).

## Re-render

```bash
cd demo
npm install
(cd .. && uv run python demo/words.py)  # only if public/voice.mp3 changed
npx remotion studio src/index.ts         # preview and scrub
npm run render                           # out/demo.mp4
npm run gif                              # docs/assets/demo.gif + demo.mp4
```

Fonts come from the system (Ubuntu, Ubuntu Sans, Ubuntu Sans Mono).
