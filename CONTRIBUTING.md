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
| `docs/` | user docs and [internal design notes](docs/design/README.md) |

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

## Recording the README demo

The README shows a still image until a demo recording exists. To replace it:

1. Record 10 to 15 seconds: press the hotkey, speak, show the live preview overlay,
   release, and show the text pasted into a window. Keep it under 10 MB.
2. Either save it as `docs/assets/demo.gif`, or drag an MP4 into a GitHub issue or
   pull request editor to get a `user-attachments` link.
3. In `README.md`, change the `src` of the image under the `DEMO` comment to that file
   or link. That is the only line that needs to change.

## Code of conduct and security

By participating you agree to the [Code of Conduct](CODE_OF_CONDUCT.md). Please report
security issues privately, as described in [SECURITY.md](SECURITY.md), not in public issues.
