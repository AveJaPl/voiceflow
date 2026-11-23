# Contributing to voiceflow

Thanks for helping. Bug reports, reports from desktops and GPUs we have not tested,
documentation fixes and code are all welcome.

## Development setup (Linux and Windows)

You need [uv](https://docs.astral.sh/uv/). It installs the pinned Python 3.13 for you.

```bash
git clone https://github.com/AveJaPl/voiceflow && cd voiceflow
uv sync
uv run pytest
```

The test suite is **hardware-free**: no GPU, microphone or display is needed, and the
same suite runs in CI on every push and pull request. Keep it that way: mock the OS,
not the logic.

The macOS and mobile ports have their own toolchains; see
[macos/README.md](macos/README.md), [android/README.md](android/README.md) and
[ios/README.md](ios/README.md). The Node services have `npm test` in
[rooms/](rooms/README.md) and [relay/](relay/README.md).

## Where things live

| path | what |
|---|---|
| `src/voiceflow/` | the Python core: daemon, CLI, transcriber, preview, recorder, injector, overlay, micmute, history, stats, rooms client, update check |
| `src/voiceflow/winplat/` | Windows backends (hotkey, recording, injection, Core Audio, mDNS) |
| `src/voiceflow/gui/` | the Qt (PySide6) desktop window used on Windows |
| `src/voiceflow/server/` | the optional HTTP transcription API |
| `app/` | the GTK4/libadwaita desktop app for Linux |
| `macos/` | the native SwiftUI menu-bar app |
| `android/` | the Android keyboard (IME) with whisper.cpp |
| `ios/` | the iOS keyboard extension and container app |
| `rooms/` | the shared dictation rooms service (Node) |
| `relay/` | the phone-to-Mac remote microphone relay (Node) |
| `windows/` | Windows installers |
| `scripts/`, `systemd/`, `install.sh` | Linux install and helper scripts |
| `tests/` | the Python test suite |
| `docs/` | user docs and [internal design notes](docs/superpowers/README.md) |

Module boundaries are load-bearing: `recorder`, `transcriber`, `injector`, `overlay`
and `micmute` must not import each other; the daemon is the only composer. Keep one
platform assumption per module, documented in its docstring.

## Reporting how it runs on your setup

voiceflow is developed on GNOME on Wayland with an NVIDIA GPU. If you run it on KDE,
Hyprland, Sway, X11, another distribution or another GPU, please file a
[platform report](https://github.com/AveJaPl/voiceflow/issues/new?template=platform_report.yml),
whether it works or not. Include the output of `voiceflow status` and the relevant log
lines (`journalctl --user -u voiceflow` on Linux, `%LOCALAPPDATA%\voiceflow\daemon.log`
on Windows).

## Commits and pull requests

- One logical change per commit, with a short summary line. Prefix it with the
  platform when the change is platform-specific (`Windows: …`, `macOS: …`).
- `uv run pytest` must pass before you open a pull request.
- For UI changes, attach a screenshot.
- User-visible changes get a line in [CHANGELOG.md](CHANGELOG.md).

## The README demo

`docs/assets/demo.gif` (silent) and `docs/assets/demo.mp4` (with voice) are generated,
not screen-recorded: a [Remotion](https://www.remotion.dev) composition in
[`demo/`](demo/README.md) redraws the overlay from `scripts/voiceflow-overlay.py`
and drives its live preview from real faster-whisper word timings. If the overlay
or the flow changes, update `demo/src/Demo.tsx` and re-render as described there.

## Code of conduct and security

By participating you agree to the [Code of Conduct](CODE_OF_CONDUCT.md). Please report
security issues privately, as described in [SECURITY.md](SECURITY.md), not in public issues.
