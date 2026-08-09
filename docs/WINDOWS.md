# voiceflow on Windows

The core — transcription, live preview, history, statistics, vocabulary,
Discord Rich Presence — is the same code as on Linux. The OS layer is swapped:

| module | Linux | Windows |
|---|---|---|
| hotkey | GNOME gsettings binding + thin client | `RegisterHotKey` **inside the daemon** — default `Ctrl+Shift+Space` |
| recording | pw-record (PipeWire) | PortAudio (`sounddevice`) |
| text injection | wl-copy + ydotool paste | Win32 clipboard + `SendInput` (default chord `ctrl+v`) |
| preview overlay | GTK popup via XWayland | tkinter always-on-top window with `WS_EX_NOACTIVATE` |
| ducking | wpctl per-stream | Core Audio sessions (`pycaw`); rules match the process name, e.g. `Spotify.exe` or `Spotify` |
| desktop window | GTK4 + libadwaita (`app/`) | Qt/PySide6 (`src/voiceflow/gui/`) — PyGObject ships no Windows wheel |
| notifications | notify-send | Windows toast (Action Center) |
| control channel | unix socket, mode 0600 | loopback TCP + a token in `%LOCALAPPDATA%\voiceflow\run\voiceflow\daemon.json` |
| Discord presence | unix socket | named pipe `\\.\pipe\discord-ipc-N` |
| paths | XDG | `%APPDATA%\voiceflow` (config), `%LOCALAPPDATA%\voiceflow` (data) |
| service | systemd --user | Startup-folder launcher (`pythonw.exe -m voiceflow daemon`) |

The command line is the same on both, because the control channel exists on
both: `voiceflow status`, `toggle`, `start`, `stop`, `cancel`, `last --copy`,
`quit`. On Windows the executable lives at
`%LOCALAPPDATA%\voiceflow\app\.venv\Scripts\voiceflow.exe`.

## Install

**Easiest:** download **`voiceflow-install.bat`** from the
[latest release](https://github.com/AveJaPl/voiceflow/releases/latest) and
double-click it. (SmartScreen may warn about an unrecognized file — choose
"More info → Run anyway"; the script is 20 lines, readable in Notepad.)

Or from any terminal (PowerShell **or** cmd, any drive):

```
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/AveJaPl/voiceflow/main/windows/install.ps1 | iex"
```

The installer stops any running copy first (so re-running it updates cleanly),
downloads the speech model (~1.6 GB) with a visible progress bar, and starts
the daemon — dictation works immediately, without waiting for a sign-out.
**voiceflow appears in the Start Menu** (with its icon) and autostarts on
login. It runs silently in the background — no console window.
Press **Ctrl+Shift+Space**, speak, press it again.

## The desktop window

**voiceflow** in the Start Menu opens the settings window: daemon status with
start/stop, dictation history with search, statistics, the full `config.yaml`
editor, and the vocabulary. It is a front end — it edits the same file the
daemon reads and talks to it over the same control channel the command line
uses, so nothing it shows is a second source of truth.

Closing the window does not stop dictation; the daemon keeps running. The
window is optional, and the hotkey works whether or not it is open.

Is it alive? Ask it:

```
%LOCALAPPDATA%\voiceflow\app\.venv\Scripts\voiceflow.exe status
```

Diagnostics live in `%LOCALAPPDATA%\voiceflow\daemon.log`. Errors also raise a
Windows toast, so a failed dictation never fails silently.

## Troubleshooting

- **Nothing pastes.** Some applications only accept `Ctrl+V`, others (terminals)
  only `Ctrl+Shift+V`. The default is `Ctrl+V`; change `inject.paste_key` in
  `%APPDATA%\voiceflow\config.yaml` if your editor wants the other one.
- **The hotkey does nothing.** Another application may already own
  `Ctrl+Shift+Space` — voiceflow says so in a toast and in the log at startup.
  Pick a free chord via `hotkey.binding` (letters, digits, `space`, `insert`,
  `pause`, `f1`–`f12`, with `ctrl`/`shift`/`alt`/`win`).
- **Dictation is slow.** Run `voiceflow.exe status`: if it reports `cpu/int8`,
  the GPU was rejected at startup and the reason is in the log.

## Known limitations (honest list)

- **GPU**: works out of the box on NVIDIA — the cuBLAS and cuDNN wheels are
  installed alongside CTranslate2 and loaded by absolute path, exactly as on
  Linux, so no CUDA Toolkit install is needed. That is roughly 1 GB of
  dependencies; on a machine without a usable NVIDIA GPU voiceflow falls back
  to CPU int8 at startup (fully functional, a few seconds per dictation).
- **Per-app microphone mute**: Windows has no public per-application capture
  mute, so the "mute Discord's mic stream" feature is a no-op — use Discord's
  own mute or push-to-talk while dictating. Playback **ducking works fully**.
- **Overlay styling** is simpler than the Linux card (tkinter, not GTK).
- The desktop window is a **separate implementation** from the GTK one, not a
  port of it: PyGObject publishes no Windows wheel, so the UI layer is Qt while
  the daemon underneath is the same code. Expect small differences in polish
  between the two.

## Status

The port is verified end to end on Windows 11 with an NVIDIA GPU: hotkey,
recording, CUDA transcription, clipboard injection, ducking, history, the
command line and the single-instance guard. Bug reports with
`%LOCALAPPDATA%\voiceflow\daemon.log` are very welcome. A signed .exe installer
(PyInstaller/Inno Setup, built on Windows CI) is on the roadmap; the .bat
bootstrap is the interim answer for non-technical users.
