# voiceflow: rooms

The service behind shared dictation sessions: who is speaking right now, a hard
talk lock for everyone else, ducking the audio for everyone in the room, and a
session leaderboard. Design: [docs/design/specs/2026-08-11-pokoje-i-sesje-design.md](../docs/design/specs/2026-08-11-pokoje-i-sesje-design.md)
(in Polish).

## What goes through this service

Presence events ("I started speaking", "I stopped") and numbers: words and
seconds. **Never audio, never the dictated text.** The `dictations` table has no
column for text, on purpose: adding one requires a migration that someone has to
approve deliberately.

## Running locally

```bash
npm install
DATABASE_URL=postgres://voiceflow:password@localhost:5432/voiceflow node server.js
```

Without `DATABASE_URL` the server refuses to start, on purpose, so that nobody can
deploy a service that comes up and only then turns out to be useless.

## Tests

```bash
npm test
```

All room logic (`src/roomState.js`) is pure functions, so the tests need neither
a database nor sockets.

## Endpoints

| method | path | purpose |
|---|---|---|
| `GET` | `/health` | health check |
| `POST` | `/api/devices` | register a device, returns a token |
| `POST` | `/api/rooms` | create a room **and its first session** |
| `POST` | `/api/rooms/:code/join` | join a device to a room |
| `POST` | `/api/rooms/:code/session/end` | close the session and open the next one |
| `GET` | `/api/rooms/:code/ranking` | members, current session and scores |
| `WS` | `/ws?room=CODE&token=…` | live presence |
| `GET` | `/room/CODE` | leaderboard page (for a tablet or a TV) |
