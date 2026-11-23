# voiceflow: relay (phone to Mac)

A WebSocket relay for the remote microphone: the iOS app acts as a hold-to-talk
microphone for the [macOS app](../macos/README.md) over the internet, not just on
local Wi-Fi. It connects **exactly one** paired couple of devices: `mac` (the
long-lived receiver) and `phone` (the audio sender). Every frame from the phone goes
1:1 to the Mac: **pure pass-through, no buffering, no decoding, no audio written to
disk.** The only thing the relay stores on disk is the pairing token, never audio.

## Running locally

```bash
npm install
ADMIN_SECRET=any-secret node server.js
```

Without `ADMIN_SECRET` the server **refuses to start**, on purpose, so that it cannot
be deployed by accident with an open `/pair` endpoint.

## Endpoints

- `GET /health`: health check, returns `{"status":"ok","service":"voiceflow-relay"}`.
- `POST /pair`: generates a new pairing token (32 random bytes, base64url) and
  **invalidates the previous one**. Requires the header
  `Authorization: Bearer <ADMIN_SECRET>`. This is a separate administrative secret,
  not the pairing token: without it anyone could mint a token and connect as the
  phone. Returns `{"token": "...", "createdAt": "..."}`.
- `wss://.../ws?role=mac&token=<token>`: the Mac's persistent connection.
- `wss://.../ws?role=phone&token=<token>`: the phone's connection, sending binary
  audio frames.

The token is shared by both roles (one pair of devices). A new connection for a role
closes the previous one (reconnect or app restart). If the Mac is not connected, the
phone immediately gets `{"type":"error","code":"mac_offline","message":"..."}`
instead of silence.

## Environment variables

| variable | required | default | description |
|---|---|---|---|
| `ADMIN_SECRET` | yes | none (startup aborts without it) | secret for `POST /pair`; generate a random string, e.g. `openssl rand -base64 32` |
| `PORT` | no | `8080` | HTTP/WS port |
| `PAIRING_STORE_PATH` | no | `./data/pairing.json` | where the active token is kept; put it on a persistent volume, or the pairing is lost on every redeploy |

## Tests

```bash
npm test
```

The tests (`node --test`) cover 1:1 phone-to-Mac pass-through, multiple frames
without buffering, the `mac_offline` error (on registration and on send), a new
connection replacing the old one for the same role, token generation and
invalidation (including surviving a process restart), rejecting WebSocket
connections with an invalid, missing or unknown-role token, `/health`, and `/pair`
with and without the correct secret. The integration tests in
`test/server.test.js` use a real `http.Server` and `ws` client, but only on loopback
(`127.0.0.1`, an ephemeral port): no internet, deterministic.

## Deploying (Docker)

1. Build from this directory with the included [Dockerfile](Dockerfile)
   (root directory `relay/` in Coolify or any Docker host).
2. Expose port `8080` (or set `PORT` and match it).
3. Set `ADMIN_SECRET` (generate it once with `openssl rand -base64 32` and keep a copy:
   you need it for every `POST /pair`). Optionally set
   `PAIRING_STORE_PATH=/data/pairing.json` if you mount a volume at `/data`.
4. Mount a **persistent volume** for the pairing store (by default `/app/data`).
   Without it the pairing token disappears on every redeploy. That is not a security
   problem (without a token nobody can connect), only an inconvenience.
5. Put it behind TLS so clients can use `wss://`.
6. Verify: `curl https://<host>/health` returns `200 {"status":"ok",...}`.
7. Pair: `curl -X POST https://<host>/pair -H "authorization: Bearer <ADMIN_SECRET>"`
   returns the token you enter in the Mac app and the iOS app.

## Checking it end to end locally

```bash
cd relay
npm install
npm test

# Terminal A: start the server
ADMIN_SECRET=local-dev-secret PORT=8091 node server.js
# the log prints a "[relay]" line with the port

# Terminal B: sanity checks
curl -i http://127.0.0.1:8091/health
# HTTP/1.1 200 OK, body {"status":"ok","service":"voiceflow-relay"}

curl -i -X POST http://127.0.0.1:8091/pair -H "authorization: Bearer wrong"
# HTTP/1.1 401 Unauthorized

curl -i -X POST http://127.0.0.1:8091/pair -H "authorization: Bearer local-dev-secret"
# HTTP/1.1 201 Created, body contains "token" and "createdAt"
```

For a full pass-through test (phone to Mac over a real WebSocket on loopback), run
`node --test test/server.test.js`: its end-to-end test sends a binary audio frame from
a phone client and asserts the Mac client receives identical bytes.
