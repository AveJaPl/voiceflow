# Design notes

Internal design specifications and implementation plans, written while building
voiceflow. They record *why* things are the way they are; they are not user
documentation (start with the [main README](../../README.md) for that).

Most of these documents are in **Polish**, the author's working language. They are
kept as written; the summaries below are in English.

## Specifications (`specs/`)

| document | what it covers |
|---|---|
| [2026-08-10-voiceflow-tray-stats-design.md](specs/2026-08-10-voiceflow-tray-stats-design.md) | the GNOME top-bar indicator with daily dictation stats (PL) |
| [2026-08-10-voiceflow-tray-charts-design.md](specs/2026-08-10-voiceflow-tray-charts-design.md) | charts in the top-bar indicator menu (PL) |
| [2026-08-11-pokoje-i-sesje-design.md](specs/2026-08-11-pokoje-i-sesje-design.md) | shared dictation rooms and sessions: talk lock, ducking, leaderboard, what is and is not sent (PL) |
| [2026-08-11-zakladka-pokoj-design.md](specs/2026-08-11-zakladka-pokoj-design.md) | the "Room" page in the desktop app (PL) |
| [2026-08-12-konta-i-synchronizacja-design.md](specs/2026-08-12-konta-i-synchronizacja-design.md) | accounts and syncing vocabulary and stats, deliberately deferred (PL) |
| [2026-08-30-serwer-api-transkrypcji-design.md](specs/2026-08-30-serwer-api-transkrypcji-design.md) | the HTTP transcription server (`voiceflow serve`) (PL) |

## Implementation plans (`plans/`)

| document | what it covers |
|---|---|
| [2026-08-10-voiceflow-tray-stats.md](plans/2026-08-10-voiceflow-tray-stats.md) | top-bar stats indicator |
| [2026-08-10-voiceflow-tray-charts.md](plans/2026-08-10-voiceflow-tray-charts.md) | top-bar charts |
| [2026-08-11-pokoje-kamien-1.md](plans/2026-08-11-pokoje-kamien-1.md) | rooms, milestone 1: a live room (PL) |
| [2026-08-11-zakladka-pokoj.md](plans/2026-08-11-zakladka-pokoj.md) | the "Room" page, part 1 of 2 (PL) |

Plans were written as step-by-step checklists for coding agents, so they read more
like task lists than prose. Where code and a plan disagree, the code is right.
