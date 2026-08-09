# voiceflow

**Press a hotkey. Speak. Your words appear in whatever window has focus.**

Local, GPU-accelerated voice dictation for Linux — a free, open-source alternative to
paid dictation apps, built for the platform they all skipped: **GNOME on Wayland**.
Whisper runs on *your* hardware. No cloud, no subscription, no audio ever leaving
your machine.

[![tests](https://github.com/AveJaPl/voiceflow/actions/workflows/ci.yml/badge.svg)](https://github.com/AveJaPl/voiceflow/actions)
[![license: MIT](https://img.shields.io/badge/license-MIT-white.svg)](LICENSE)
[![python 3.13](https://img.shields.io/badge/python-3.13-white.svg)](pyproject.toml)
[![platform](https://img.shields.io/badge/platform-Linux%20%C2%B7%20GNOME%2FWayland-white.svg)](#requirements)

![live preview while dictating](docs/assets/preview.png)

*The on-screen preview while you speak — it updates every second and never steals focus.
Release the hotkey and the final, full-context transcription is pasted where your cursor is.*

## Install

One command, no git needed:

```bash
curl -fsSL https://raw.githubusercontent.com/AveJaPl/voiceflow/main/install.sh | bash
```

(Prefer to look before you run? `curl -fsSL …/install.sh > install.sh`, read it, then
`bash install.sh`. The only step that needs sudo is installing `ydotool` and a udev
rule for `/dev/uinput` — the script explains why.)

First start downloads the speech model (~1.6 GB). After that: press **`Super+G`**,
speak, press **`Super+G`** again. That's the whole workflow.

<details>
<summary>Manual install from source</summary>

```bash
git clone https://github.com/AveJaPl/voiceflow && cd voiceflow
sudo bash scripts/install-system-deps.sh   # ydotool, wl-clipboard, udev rule
uv sync                                    # pinned Python 3.13 + dependencies
mkdir -p ~/.local/bin
printf '#!/usr/bin/env bash\nexec "%s/.venv/bin/voiceflow" "$@"\n' "$PWD" > ~/.local/bin/voiceflow
chmod +x ~/.local/bin/voiceflow
systemctl --user enable --now ydotool.service
cp systemd/voiceflow.service ~/.config/systemd/user/
systemctl --user daemon-reload && systemctl --user enable --now voiceflow.service
bash scripts/install-hotkey.sh             # Super+G by default
```
</details>

## Why this exists

Dictating prompts to AI assistants beats typing them — but the good dictation apps are
subscription cloud services, and none of them run on Linux at all. voiceflow does the
same job with a local Whisper model:

|  | voiceflow | typical paid dictation app |
|---|---|---|
| price | free, MIT | ~$15/month |
| audio leaves your machine | never | always |
| Linux / GNOME / Wayland | native | unsupported |
| latency after you stop speaking | ~0.1 s on a GPU | network round-trip |
| works offline | yes | no |

## Features

- **Fast.** A user daemon keeps the model warm in VRAM: on an RTX 3070,
  `large-v3-turbo` transcribes 4 s of speech in ~0.04 s. No GPU? It falls back to
  CPU (`int8`) automatically — slower, still private.
- **Live preview.** A minimal always-on-top card shows what the model hears while you
  are still talking, with a pulsing recording indicator. The pasted text is a second,
  full-context pass — accuracy is never sacrificed for the preview.
- **Voice-chat aware.** Dictating while on Discord? Your mic stream to the call is
  muted (they never hear your prompts) and the call's audio is ducked to 40% (it stops
  derailing your sentence). Both restored the instant recording ends; your manual mute
  is respected.
- **Any language.** Whatever Whisper speaks — set `model.language` (`en`, `de`, `pl`, …
  or `null` to auto-detect).
- **Custom vocabulary.** Your product names and jargon, biased into the decoder so it
  stops mangling them (`model.vocabulary`). It biases only — never rewrites your words.
- **Honest with your clipboard.** Text is injected via paste (the only non-ASCII-safe
  path on GNOME Wayland) and your previous clipboard is put back afterwards.
- **Tested without hardware.** 67 tests, none need a GPU, microphone, or display —
  they run in CI on every commit.

## Requirements

| | |
|---|---|
| OS | Linux with **PipeWire** (developed on Ubuntu 26.04) |
| Desktop | **GNOME on Wayland** (developed on GNOME 50) — other compositors: [see roadmap](#roadmap) |
| GPU | optional; NVIDIA with ~2.5 GB free VRAM for `large-v3-turbo` (CUDA libraries come from pip — **no CUDA Toolkit install needed**) |
| Disk | ~1.6 GB model + ~2.7 GB environment |

## Usage

| | |
|---|---|
| dictate | `Super+G` → speak → `Super+G` |
| cancel without pasting | `voiceflow cancel` |
| health check & diagnostics | `voiceflow status` |
| logs | `journalctl --user -u voiceflow -f` |
| change the hotkey | `VOICEFLOW_BINDING='<Control><Alt>space' bash scripts/install-hotkey.sh` |
| free the VRAM (before gaming) | `systemctl --user stop voiceflow` |
| stress-test / leak check | `bash scripts/audit.sh` |

## Configuration

`~/.config/voiceflow/config.yaml` — created with commented defaults on first run;
restart the daemon after editing.

```yaml
model:
  name: large-v3-turbo    # any faster-whisper model
  device: cuda            # cuda | cpu | auto
  language: pl            # ISO 639-1; null = auto-detect
  vocabulary: []          # names the decoder should lean towards
inject:
  method: clipboard       # clipboard | ydotool | auto
  paste_key: ctrl+shift+v # terminals paste with shift; GUI apps may want ctrl+v
mute_apps:
  apps: [WEBRTC VoiceEngine]   # Discord's mic stream; find others via pw-dump
  duck_volume: 0.4        # duck the call to 40% while dictating
```

<details>
<summary>Full configuration reference</summary>

| key | default | meaning |
|---|---|---|
| `model.name` | `large-v3-turbo` | any faster-whisper model id |
| `model.device` | `cuda` | `cuda` / `cpu` / `auto`; CUDA failure falls back to CPU |
| `model.compute_type` | `float16` | precision on GPU; CPU uses `int8` |
| `model.language` | `pl` | ISO 639-1 code or `null` for auto-detect |
| `model.beam_size` | `5` | decoder beam width |
| `model.vocabulary` | `[]` | terms biased into decoding |
| `audio.source` | `null` | PipeWire source; `null` = default mic |
| `audio.max_seconds` | `300` | safety cap on one recording |
| `inject.method` | `clipboard` | `ydotool` types ASCII only; `clipboard` is safe for all languages |
| `inject.paste_key` | `ctrl+shift+v` | the paste chord that gets sent |
| `inject.restore_clipboard` | `true` | put the previous clipboard back |
| `preview.enabled` | `true` | live preview while speaking |
| `preview.interval_seconds` | `1.0` | preview refresh rate |
| `mute_apps.enabled` | `true` | mute configured apps' mic streams while recording |
| `mute_apps.apps` | `[WEBRTC VoiceEngine]` | PipeWire `application.name` values |
| `mute_apps.duck_enabled` | `true` | also duck those apps' playback |
| `mute_apps.duck_volume` | `0.4` | duck target as a fraction of full volume |
| `overlay.enabled` | `true` | the on-screen indicator card |

The config file is generated once and not migrated — delete it to regenerate with
current defaults.
</details>

## How it works

```
hotkey ─▶ voiceflow toggle ──unix socket──▶ voiceflow daemon (systemd --user)
                                             ├─ recorder     pw-record, 16 kHz WAV
                                             ├─ transcriber  faster-whisper, warm in VRAM
                                             ├─ preview      re-transcribes the tail every 1 s
                                             ├─ overlay      separate GTK3 process (X11 popup)
                                             ├─ micmute      mutes/ducks voice chats (wpctl)
                                             └─ injector     wl-copy + paste keystroke
```

A thin client (~0.1 s startup) talks to a persistent daemon, so the model loads once
per login, not once per dictation. The modules do not import each other — the daemon
composes them — which is what keeps the test suite hardware-free and the platform
ports tractable.

<details>
<summary>Why GNOME/Wayland needed all this (field notes)</summary>

Constraints discovered the hard way — read this before porting:

- **You cannot type into another window.** Wayland forbids input injection and GNOME
  implements no `virtual-keyboard` protocol, so `wtype` is out. `ydotool` works at the
  kernel level via `/dev/uinput`, but its `type` command silently drops non-ASCII
  characters. Hence: clipboard + a real paste keystroke, clipboard restored after.
- **A window cannot refuse focus** — a normal preview window would swallow the paste.
  The overlay is an X11 override-redirect popup via XWayland: the one window type the
  compositor neither focuses nor repositions.
- **`pw-record` exits 1 after SIGINT** even when the WAV is complete. Success must be
  judged by parsing the WAV header, not the exit code.
- **`wl-copy` forks**, and its child owns the Wayland selection; piping its stdio and
  waiting for EOF deadlocks every paste. No pipes to self-daemonizing processes.
- **User services race the login.** From `default.target` the daemon gets no
  `DISPLAY`/`XAUTHORITY`; the unit binds to `graphical-session.target`, with a runtime
  fallback that locates Mutter's XWayland auth cookie.
</details>

## Roadmap

Ordered by how much of the codebase carries over — the daemon, transcriber, preview
logic, vocabulary, and config are already platform-neutral; only `recorder`,
`injector`, `overlay`, and `micmute` touch the OS:

- [ ] **Native settings app** (GTK4/libadwaita) — status, model & language, vocabulary
  editor, voice-chat ducking, all without touching YAML *(in progress)*
- [ ] **Other Wayland compositors** (KDE, Hyprland, Sway) — easiest port: they
  implement `virtual-keyboard`/layer-shell, so injection and overlay get *simpler*
  ([#1](https://github.com/AveJaPl/voiceflow/issues/1))
- [ ] **Prebuilt packages** — .deb, AUR, Flatpak/AppImage (the `/dev/uinput` access
  needs design work in sandboxed formats) ([#4](https://github.com/AveJaPl/voiceflow/issues/4))
- [ ] **Windows** — CUDA works out of the box; needs a WASAPI recorder, `SendInput`
  injection, a layered-window overlay, and a global hotkey ([#2](https://github.com/AveJaPl/voiceflow/issues/2))
- [ ] **macOS** — AVFoundation recorder, CGEvent paste, NSPanel overlay, Accessibility
  permissions; Apple Silicon inference via CPU or an mlx/whisper.cpp backend ([#3](https://github.com/AveJaPl/voiceflow/issues/3))
- [ ] **Android / iOS** — as custom keyboards (IME / keyboard extension) with on-device
  whisper.cpp, so dictation works in every app; effectively sibling projects
  ([#6](https://github.com/AveJaPl/voiceflow/issues/6),
  [#7](https://github.com/AveJaPl/voiceflow/issues/7))
- [ ] **i18n** of user-facing strings (currently Polish — the author dictates in Polish)
  ([#5](https://github.com/AveJaPl/voiceflow/issues/5))

Each item has a tracking issue with implementation notes — grab one, comment, and go.

## Contributing

PRs and issues welcome. Ground rules are short:

- `uv run pytest` must stay green and hardware-free — mock the OS, not the logic.
- Module boundaries are load-bearing: `recorder`/`transcriber`/`injector`/`overlay`/
  `micmute` must not import each other. The daemon is the only composer.
- One platform assumption per module, documented in its docstring.

## License

[MIT](LICENSE) © Filip Piątek
