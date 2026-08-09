# voiceflow landing — design system

Reference aesthetic: **ElevenLabs** (dark cinematic, audio-waveform motifs),
adapted to voiceflow's existing identity: matte black, monochrome, premium —
the same language as the dictation overlay and the GTK app. One accent only:
pure white. Inspiration pin: "Vocal — your voice, reimagined".

## 1. Atmosphere
Cinematic matte black; the waveform is the only living element. Generous
vertical whitespace, monumental typography, zero color noise.

## 2. Color
--bg: #0a0a0b        page ground
--surface: #131315   cards
--surface-2: #1a1a1d hover / nested
--text: #f5f5f7      primary (the icon's white)
--muted: #9a9aa2     secondary
--faint: #55555c     tertiary / captions
--border: #232326    1px hairlines
--accent: #ffffff    CTAs (white button, black text)

## 3. Typography
Display: Inter, weight 600, letter-spacing -0.045em, clamp(2.8rem → 5.5rem).
Body: Inter 400/500, 1rem/1.7.
Code/commands: JetBrains Mono 400, 0.875rem.

## 4. Components
Primary button: white bg, black text, radius 10px, hover lifts 1px + subtle
white glow. Secondary: transparent, 1px border, white text. Cards: surface,
1px border, radius 14px, no shadows (matte — same rule as the overlay).
Command boxes: mono font, surface, copy button appearing on hover.

## 5. Layout
max-width 1120px, 8px rhythm, sections separated by 120–160px. One column
hero, features in 3-col grid (1-col mobile).

## 6. Depth
Borders over shadows. Elevation = surface step (bg → surface → surface-2).
The only glow allowed: the recording dot and canvas waveform.

## 7. Do / Don't
DO: monochrome everything; waveform motifs; huge tight display type.
DON'T: no colored accents, no gradients-as-decoration, no drop shadows,
no rounded-pill buttons, no stock illustrations.

## 8. Responsive
Breakpoint 720px: grid → 1 col, nav collapses to logo + GitHub, hero type
clamps down. Touch targets ≥44px.

## 9. Motion
Waveform canvas ~60fps, amplitude breathes slowly. Reveal-on-scroll:
opacity+8px translate, 0.5s ease-out, once. `prefers-reduced-motion`
disables both.
