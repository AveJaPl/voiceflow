# README demo (generated)

A 13-second [Remotion](https://www.remotion.dev) composition: `Super+G`, a dictated
request, the live preview card, `Super+G` again, and the text pasted into a Claude Code
session on Ubuntu (GNOME, Wayland). It produces `docs/assets/demo.mp4` (1080p, with
voice) and `docs/assets/demo.gif` (silent, for the README).

Everything is drawn at true 1:1 scale on a 1920×1080 screen; the GIF stays readable
through a camera zoom, not by enlarging the product.

What is faithful and what is drawn:

- **The overlay card** copies `scripts/voiceflow-overlay.py`: 828 px wide, 90 px above
  the bottom edge, 18 px padding, five 24 px lines, 8 px dot breathing every 1.8 s and
  dimming to 34 % during the final pass, `rgba(15,15,17,.94)` with a 1 px border and an
  inset top highlight. Its CSS font list starts with "SF Pro Text", "Inter"; on Ubuntu
  the first installed one is Inter, so Inter 17 px is what the card really uses.
- **The live preview** at each one-second tick is exactly what faster-whisper
  (`large-v3-turbo`, same model as the app) places before that moment in
  `public/voice.mp3`. Timings live in `src/words.json`, made by `words.py`.
- **The desktop** is a stock Ubuntu 26.04 setup: Raccoon "Very Dark" wallpaper, Ubuntu
  dock on the left at full height with 48 px icons (Yaru / GNOME app icons), the GNOME
  top bar, and Ptyxis with its "GNOME" dark palette (`#1c1c1f`, title bar `#2e2e32`) and
  FiraCode Nerd Font Mono 12.
- **Drawn for the story:** the Claude Code session, the agent's reply and the key hints.
  The voice is synthetic (ElevenLabs).
- The idle placeholders the real card shows ("Słucham…", "Przetwarzam…") are left out
  until the UI is translated (#5).

## Re-render

```bash
cd demo
npm install
(cd .. && uv run python demo/words.py)  # only if public/voice.mp3 changed
npx remotion studio src/index.ts         # preview and scrub
npm run render                           # out/demo.mp4
npm run gif                              # docs/assets/demo.gif + demo.mp4
```

Fonts come from the system (Inter, Ubuntu Sans, FiraCode Nerd Font Mono).

## Credits

- Wallpaper: *Low poly Raccoon (Very Dark)* by Vladimir Moskalenko, from Ubuntu's
  wallpapers, [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/).
- App and status icons: GNOME (hicolor) and Yaru icon themes, CC BY-SA.
