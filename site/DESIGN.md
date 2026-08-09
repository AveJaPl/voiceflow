# voiceflow landing — design system v2 ("Stoic")

Direction chosen by Filip (2026-08-09) from Pinterest: a mix of
**STOICISM** (dignified dark editorial: classical sculpture, single gold
accent, serif display, numbered chapters) and **Digital Designer**
(a human in frame; the product shown concretely). Goal: premium, stately —
"you enter and feel like a god". Not a SaaS template.

## 1. Atmosphere
A dark gallery at night. Marble, one warm light, gold leaf. Generous
emptiness; every section a numbered chapter. Imagery (Codex-generated):
marble bust speaking a golden waveform, a suited figure dictating,
a marble hand. Images vignette into the page background — no visible frames.

## 2. Color
--bg: #0B0A09        warm near-black (images blend into it)
--surface: #14110F   panels, code blocks
--text: #EDE8DF      warm ivory
--muted: #9C948A
--faint: #5D574E
--border: #272220    hairlines
--gold: #C9A45C      THE accent: numerals, rules, icons, hover
--gold-dim: #C9A45C59

## 3. Typography
Display: "Cormorant Garamond" 500/600 (+italic for emphasis), tight
leading, large sizes — headline clamp(3rem → 6rem).
Labels/eyebrows: Inter 600, 0.14em tracking, uppercase, 0.75rem.
Body: Inter 400, 1rem/1.75. Code: JetBrains Mono.
Numerals in stats: Cormorant, gold.

## 4. Components
No cards-with-borders grids. Editorial lists separated by 1px hairlines;
gold section numbers ("01", "02"…). Buttons: gold outline, serif-adjacent
feel, fill-on-hover (gold bg, near-black text). Code blocks: surface,
hairline, gold copy icon. Icons: Lucide inline SVG, stroke 1.5,
currentColor (gold or ivory). NO emoji anywhere.

## 5. Layout
max-width 1200px; hero full-bleed image; sections 140–180px apart with
hairline + number + serif title pattern. Asymmetric two-column sections
(image/text) for the portrait and the hand.

## 6. Depth
No shadows. Depth = photography and vignettes. Surfaces one step lighter.

## 7. Do / Don't
DO: serif display, gold only as scarce accent, real imagery, numbered
chapters, show the product doing real work (mail, chat, code).
DON'T: emoji, colored gradients, rounded-pill buttons, card grids,
more than one accent color, stock-photo brightness.

## 8. Responsive
≤760px: single column, images become section headers, hero text over
darkened image, nav collapses to wordmark + GitHub.

## 9. Motion
Slow and dignified: 0.6s ease-out reveals, the dictation demo types at
human pace, waveform shimmer on gold lines only. prefers-reduced-motion
disables all.
