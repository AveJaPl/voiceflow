# voiceflow

**Local, GPU-accelerated voice dictation for Linux.** Press a hotkey, speak, press it
again — the transcribed text lands in whatever window has focus. Whisper runs on your
own hardware: no cloud, no subscription, no audio leaving your machine.

Built as a free alternative to paid dictation apps (Wispr Flow and friends), on a stack
where those apps do not run at all: **GNOME on Wayland**.

```
┌──────────────────────────────────────────────────┐
│  ●  write me a function that computes the mean   │
│     of a list and returns zero when it is empty… │
└──────────────────────────────────────────────────┘
        on-screen preview while you speak
```

## What it does

- **Hotkey-driven dictation** (`Super+G` by default): toggle recording, speak, toggle
  again, text is pasted into the focused window — terminal, browser, editor, anything.
- **Live preview**: a small always-on-top card shows what the model hears *while you
  are still speaking*, with a pulsing recording indicator. It never steals focus.
- **Fast**: the daemon keeps the Whisper model loaded in VRAM. On an RTX 3070,
  `large-v3-turbo` transcribes 4 s of speech in ~0.04 s. Falls back to CPU (`int8`)
  automatically when CUDA is unavailable.
- **Voice-chat aware**: while you dictate, the microphone stream of Discord (or any
  configured app) is muted so your call does not hear your prompts, and the call's
  playback is ducked so it does not distract you. Both restored the moment recording
  ends. Your manual mute state is respected.
- **Any language Whisper supports** — set `model.language` in the config (the default
  config ships with `pl`; use `en`, `de`, … or `null` for auto-detection).
- **Custom vocabulary**: a list of names/jargon the decoder should lean towards
  (`model.vocabulary`), so it stops mangling your product names. Biases decoding only —
  never rewrites your words.

## Requirements

| | |
|---|---|
| OS | Linux with **PipeWire** (tested: Ubuntu 26.04) |
| Desktop | **GNOME on Wayland** (tested: GNOME 50; see [Why GNOME/Wayland is hard](#why-gnomewayland-is-hard) — other compositors likely need changes) |
| GPU | NVIDIA with ~2.5 GB free VRAM for `large-v3-turbo` (optional — CPU fallback works, just slower) |
| Python | 3.13 via [uv](https://docs.astral.sh/uv/) (3.14 not yet supported by CTranslate2) |
| Disk | ~1.6 GB model weights + ~2.7 GB virtualenv (CUDA libraries from pip — no system CUDA Toolkit needed) |

## Install

```bash
git clone https://github.com/AveJaPl/voiceflow
cd voiceflow

# 1. System dependencies: ydotool, wl-clipboard, /dev/uinput udev rule
sudo bash scripts/install-system-deps.sh

# 2. Python environment (uv downloads a pinned Python 3.13 by itself)
uv sync

# 3. Make the CLI available
mkdir -p ~/.local/bin
printf '#!/usr/bin/env bash\nexec "%s/.venv/bin/voiceflow" "$@"\n' "$PWD" > ~/.local/bin/voiceflow
chmod +x ~/.local/bin/voiceflow

# 4. Start the ydotool daemon and the voiceflow daemon (user services, no root)
systemctl --user enable --now ydotool.service
cp systemd/voiceflow.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now voiceflow.service

# 5. Register the GNOME hotkey (default Super+G; see the script for overrides)
bash scripts/install-hotkey.sh
```

First start downloads the model (~1.6 GB) and can take a few minutes; check progress
with `journalctl --user -u voiceflow -f`. Every later start loads from cache in ~1.5 s.

Verify with `voiceflow status` — it reports the daemon state, the device the model
actually loaded on, and a full injection-path diagnostic.

## Usage

| | |
|---|---|
| dictate | `Super+G`, speak, `Super+G` |
| cancel without pasting | `voiceflow cancel` |
| health check | `voiceflow status` |
| logs | `journalctl --user -u voiceflow -f` |
| change hotkey | `VOICEFLOW_BINDING='<Control><Alt>space' bash scripts/install-hotkey.sh` |
| stress-test / leak check | `bash scripts/audit.sh` |

## Configuration

`~/.config/voiceflow/config.yaml`, created with commented defaults on first run.
Restart the daemon after editing (`systemctl --user restart voiceflow`).

```yaml
model:
  name: large-v3-turbo    # any faster-whisper model
  device: cuda            # cuda | cpu | auto
  language: pl            # ISO 639-1; null = auto-detect
  vocabulary: []          # names the decoder should lean towards
audio:
  source: null            # PipeWire source; null = default mic
inject:
  method: clipboard       # clipboard | ydotool | auto
  paste_key: ctrl+shift+v # terminals paste with shift; GUI apps may want ctrl+v
  restore_clipboard: true # put the previous clipboard back after pasting
preview:
  enabled: true           # live preview while speaking
mute_apps:
  enabled: true
  apps: [WEBRTC VoiceEngine]   # Discord's mic stream; find yours via pw-dump
  duck_enabled: true
  duck_volume: 0.4        # duck the call to 40% while dictating
overlay:
  enabled: true           # the on-screen indicator card
```

Note: the config file is generated once and not migrated — new options appear in fresh
installs. Delete the file to regenerate with current defaults.

## Architecture

```
hotkey → voiceflow toggle ──unix socket──▶ voiceflow daemon (systemd --user)
                                            ├─ recorder    pw-record, 16 kHz WAV
                                            ├─ transcriber faster-whisper, model held in VRAM
                                            ├─ preview     re-transcribes the tail every 1 s
                                            ├─ overlay     separate GTK3 process (X11 popup)
                                            ├─ micmute     mutes/ducks voice chats via wpctl
                                            └─ injector    wl-copy + ydotool paste keystroke
```

A thin client talks to a persistent daemon over a unix socket, so the hotkey responds
in ~0.1 s while the model stays warm. The modules do not know about each other; the
daemon composes them, which keeps each one testable without a GPU or a microphone
(67 tests, none require hardware).

## Why GNOME/Wayland is hard

These are the platform constraints this project exists to work around — useful reading
before porting it anywhere:

- **You cannot type into another window.** Wayland forbids input injection, and GNOME
  implements no `virtual-keyboard` protocol, so `wtype` is out. `ydotool` works via
  `/dev/uinput` (kernel level), but its `type` command silently drops non-ASCII
  characters — fatal for most languages. Hence the default path: clipboard + a real
  paste keystroke, with the previous clipboard restored afterwards.
- **A window cannot refuse focus.** A normal preview window would steal focus and
  swallow the paste. The overlay is an X11 override-redirect popup (via XWayland) —
  the one window type the compositor neither focuses nor repositions.
- **`pw-record` exits 1 after SIGINT** even when the WAV is perfectly fine. The exit
  code is not a success signal; the WAV header is.
- **`wl-copy` forks** and its child owns the Wayland selection; piping its stdio and
  waiting for EOF deadlocks every paste.
- **User services race the login.** Started from `default.target`, the daemon gets no
  `DISPLAY`/`XAUTHORITY` and the overlay cannot authenticate to X. The unit binds to
  `graphical-session.target`, plus a runtime fallback that locates Mutter's
  XWayland auth cookie.

## Contributing

Issues and PRs welcome. Things that would genuinely help:

- **Other compositors** (KDE, Hyprland, Sway) — the injector and overlay are the two
  modules with GNOME-specific assumptions; both are isolated behind small interfaces.
- **Packaging** — a .deb, an AUR package, a Flatpak (the uinput access needs thought).
- **i18n** — user-facing strings are currently Polish (the author dictates in Polish);
  extracting them is a small, well-contained task.
- **A GNOME Shell extension overlay** — would allow real background blur and drop the
  XWayland dependency.

Run the test suite with `uv run pytest` (no GPU or microphone needed). Please keep the
module boundaries: `recorder`/`transcriber`/`injector`/`overlay`/`micmute` must not
import each other.

## License

[MIT](LICENSE)
