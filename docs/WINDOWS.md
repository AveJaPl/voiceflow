# voiceflow on Windows (beta)

The core — transcription, live preview, history, statistics, vocabulary,
Discord Rich Presence — is the same code as on Linux. The OS layer is swapped:

| module | Linux | Windows |
|---|---|---|
| hotkey | GNOME gsettings binding + thin client | `RegisterHotKey` **inside the daemon** — default `Ctrl+Shift+Space` |
| recording | pw-record (PipeWire) | PortAudio (`sounddevice`) |
| text injection | wl-copy + ydotool paste | Win32 clipboard + `SendInput` (default chord `ctrl+v`) |
| preview overlay | GTK popup via XWayland | tkinter always-on-top window with `WS_EX_NOACTIVATE` |
| ducking | wpctl per-stream | Core Audio sessions (`pycaw`); rules match the process name, e.g. `Spotify.exe` or `Spotify` |
| Discord presence | unix socket | named pipe `\\.\pipe\discord-ipc-N` |
| paths | XDG | `%APPDATA%\voiceflow` (config), `%LOCALAPPDATA%\voiceflow` (data) |
| service | systemd --user | Startup-folder launcher |

## Install

```powershell
irm https://raw.githubusercontent.com/AveJaPl/voiceflow/main/windows/install.ps1 | iex
```

Then run `%LOCALAPPDATA%\voiceflow\voiceflow.bat` (or just log in again — it
autostarts). First start downloads the model (~1.6 GB). Press
**Ctrl+Shift+Space**, speak, press it again.

## Known limitations (honest list)

- **GPU**: CTranslate2 on Windows needs system cuBLAS/cuDNN for CUDA (the pip
  CUDA wheels are Linux-only). Without them voiceflow automatically runs on
  CPU int8 — fully functional, a few seconds per dictation instead of instant.
  With an NVIDIA card, installing [cuDNN 9](https://developer.nvidia.com/cudnn)
  enables `device: cuda`.
- **Per-app microphone mute**: Windows has no public per-application capture
  mute, so the "mute Discord's mic stream" feature is a no-op — use Discord's
  own mute or push-to-talk while dictating. Playback **ducking works fully**.
- **Overlay styling** is simpler than the Linux card (tkinter, not GTK).
- The GTK settings app is Linux-only for now; on Windows edit
  `%APPDATA%\voiceflow\config.yaml` (same format, same keys).

## Status

This port is **beta**: written against the Win32 API and tested primarily on
one machine. Bug reports with `%LOCALAPPDATA%\voiceflow` logs are very welcome
— see the tracking issue for what remains.
