# voiceflow on Windows

The core — transcription, live preview, history, statistics, vocabulary,
Discord Rich Presence — is the same code as on Linux. The OS layer is swapped:

| module | Linux | Windows |
|---|---|---|
| hotkey | GNOME gsettings binding + thin client | `RegisterHotKey` **inside the daemon** — default `Ctrl+Shift+Space` |
| recording | pw-record (PipeWire) | PortAudio (`sounddevice`) |
| text injection | wl-copy + ydotool paste | Win32 clipboard + `SendInput` (default chord `ctrl+v`) |
| preview overlay | GTK popup via XWayland | tkinter always-on-top window with `WS_EX_NOACTIVATE` |
| mic mute | wpctl on the app's `Stream/Input/Audio` node | Core Audio capture session per process (`pycaw`); apps named by executable, e.g. `Discord.exe` |
| ducking | wpctl per-stream | Core Audio sessions (`pycaw`); rules match the process name, e.g. `Spotify.exe` or `Spotify` |
| desktop window | GTK4 + libadwaita (`app/`) | Qt/PySide6 (`src/voiceflow/gui/`) — PyGObject ships no Windows wheel |
| room discovery | Avahi over D-Bus | mDNS through `zeroconf` — same protocol, so the two see each other |
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

**Installing the working copy.** While the window or the daemon is being worked
on, the installed copy is whatever release was downloaded last, so the Start
Menu icon opens yesterday's application. `windows\install-local.ps1` makes the
installed copy *this* checkout, keeping the environment and the downloaded
model:

```
powershell -NoProfile -ExecutionPolicy Bypass -File windows\install-local.ps1
```

**Why the launcher is repaired after `uv sync`.** uv builds
`.venv\Scripts\pythonw.exe` as a trampoline that re-launches the *console*
interpreter of the base installation, and a console program whose parent has no
console to inherit is handed a new console window of its own — so every
windowless start opened a black window full of log lines over the user's work,
the desktop window arriving behind it. Both installers replace that trampoline
with the real `pythonw.exe` (the DLLs beside it included, exactly as
`python -m venv` does), so no console is ever created. `python.exe` is left
alone: the command line wants its console. Should a copy still be launched
through a trampoline, the daemon and the window free a console of their own at
startup — one shared with a shell is left alone, and `VOICEFLOW_KEEP_CONSOLE=1`
keeps even ours.

## The desktop window

**voiceflow** in the Start Menu opens the same window Linux has, page for page:
**Przegląd** (daemon status with start/stop and a dictation button, today's and
total counts, the week as a sparkline, the last dictation), **Historia**
(searchable, grouped by day, each entry expandable), **Statystyki** (totals, the
fortnight as bars, 26 weeks as an activity grid), **Pokój** (create or join a
shared room, rooms advertised on your network, the live board), **Sesje** (the
room's closed sessions and each person's total), **Słownik**, and
**Ustawienia**. It is a front end — it edits the same file the daemon reads and
talks to it over the same control channel the command line uses, so nothing it
shows is a second source of truth.

Edits on the settings and vocabulary pages collect in one **Niezapisane zmiany**
bar at the bottom: **Zastosuj** writes `config.yaml` and restarts the daemon,
**Cofnij** re-reads the file. Nothing is written until you press one of them.

Closing the window does not stop dictation; the daemon keeps running. The
window is optional, and the hotkey works whether or not it is open.

Is it alive? Ask it:

```
%LOCALAPPDATA%\voiceflow\app\.venv\Scripts\voiceflow.exe status
```

Diagnostics live in `%LOCALAPPDATA%\voiceflow\daemon.log`. Errors also raise a
Windows toast, so a failed dictation never fails silently.

## How fast it is, and why

Without an NVIDIA GPU the model runs on the CPU, and two numbers shape
everything else. Threads: CTranslate2 takes four regardless of the machine, so
voiceflow gives it one per physical core instead — on an i7-1260P (4+8 cores)
that is 20 s of Polish transcribed in 9.8 s rather than 12.2 s. Window: Whisper's
encoder always processes 30 seconds, however little audio is in it, so 6 s of
speech costs 7.6 s and 29 s costs 11.8 s. That second number is why decoding
cannot be made granular — and why `large-v3-turbo` is only "turbo" in its
decoder, its encoder being the full `large-v3` one.

So the wait is attacked where it can be: what has already been said is
transcribed during the pauses (see `incremental` in `config.yaml`), leaving only
the stretch since the last pause for after the hotkey. A 50 s dictation waits
10 s instead of 25 s; a dictation shorter than one window is transcribed in one
pass exactly as before, because there is nothing to overlap it with. On a GPU
all of this is moot — a window decodes in well under a second.

Two levers remain if that is still too slow: `model.name: small` transcribes
three times faster than turbo (3.3 s against 9.8 s on the same sample) at a
visible cost in Polish and in technical vocabulary, and `preview.enabled: false`
stops the live preview from spending a whole encoder window every second on text
nobody keeps.

## Troubleshooting

- **Nothing pastes.** Some applications only accept `Ctrl+V`, others (terminals)
  only `Ctrl+Shift+V`. The default is `Ctrl+V`; change `inject.paste_key` in
  `%APPDATA%\voiceflow\config.yaml` if your editor wants the other one.
- **Nothing pastes at all, and the text is in the clipboard.** Then something
  else held the focus when the paste chord was sent — it goes to whatever window
  is in front. The preview card used to be that something: tkinter takes the
  foreground the instant it realizes its window, ahead of the `WS_EX_NOACTIVATE`
  that is meant to stop exactly this, so the card now hands the focus back to
  the window that had it. If it happens with another application in front, check
  whether that application runs as administrator: Windows refuses synthesized
  input from an unelevated process to an elevated window, and the log says so.
- **"Skrót NIE działa — zajmuje go inna aplikacja", and no other application
  does.** Then it was voiceflow: a second daemon cannot register a shortcut the
  first one holds. Since the instance lock this cannot happen from a launch any
  more, but a copy installed before it can still be running —
  `voiceflow.exe quit`, then start it once from the Start Menu.
- **The hotkey does nothing.** Another application may already own
  `Ctrl+Shift+Space` — voiceflow says so in a toast, in the log at startup, and
  on the dashboard, which reports the shortcut as not working rather than
  merely naming it. Record a new one in Ustawienia: press "Nagraj skrót", press
  the chord (the Windows key included — the recorder sits ahead of the shell),
  and the field says immediately whether Windows will grant it. By hand,
  `hotkey.binding` takes letters, digits, `space`, `insert`, `pause`, `f1`–`f24`
  with `ctrl`/`shift`/`alt`/`win`.
- **The collision-proof option.** `F13`–`F24` exist in Windows but on no
  physical keyboard, so nothing can ever claim them. Remap Caps Lock to F13
  (PowerToys Keyboard Manager) and bind `f13`: one key, one finger, no conflict.
- **Dictation is slow.** Run `voiceflow.exe status`: if it reports `cpu/int8`,
  the GPU was rejected at startup and the reason is in the log.

## Known limitations (honest list)

- **GPU**: works out of the box on NVIDIA — the cuBLAS and cuDNN wheels are
  installed alongside CTranslate2 and loaded by absolute path, exactly as on
  Linux, so no CUDA Toolkit install is needed. That is roughly 1 GB of
  dependencies; on a machine without a usable NVIDIA GPU voiceflow falls back
  to CPU int8 at startup (fully functional, a few seconds per dictation).
- **Per-app microphone mute** works, but only for applications recording
  through **WASAPI** — those own a capture session Core Audio can mute
  individually, which covers Discord and the other current voice chats. An
  application still using the legacy MME or DirectSound paths is proxied by the
  Windows audio service and cannot be singled out; it will not appear in the
  detected-applications list, and for it push-to-talk remains the answer.
- **Overlay styling** is simpler than the Linux card (tkinter, not GTK).
- The desktop window is a **separate implementation** from the GTK one — Qt,
  because PyGObject publishes no Windows wheel — but it is a deliberate port,
  not a relative: the same pages, the same layout, the same palette, the same
  wording. Two knowing differences remain, both because Windows can do something
  Linux cannot or vice versa: the dictation shortcut is recorded by pressing it
  (the daemon owns the hotkey here, so it can also report that Windows refused
  it, which the overview says out loud), and the settings page has one extra
  group — recording limit, preview timings, history, update checks,
  notifications — for keys that exist in `config.yaml` on both systems but that
  the GTK window does not expose yet.
- **Room discovery needs the window open**, exactly as on Linux: the mDNS
  announcement lives in the application, not the daemon. The room code and the
  link work regardless.

## Status

The port is verified end to end on Windows 11 with an NVIDIA GPU: hotkey,
recording, CUDA transcription, clipboard injection, ducking, history, the
command line and the single-instance guard. Bug reports with
`%LOCALAPPDATA%\voiceflow\daemon.log` are very welcome. A signed .exe installer
(PyInstaller/Inno Setup, built on Windows CI) is on the roadmap; the .bat
bootstrap is the interim answer for non-technical users.
