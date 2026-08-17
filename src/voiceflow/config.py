"""Typed configuration loading and default file creation."""

from __future__ import annotations

import logging
import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Mapping

import yaml

from voiceflow.paths import config_dir

LOGGER = logging.getLogger(__name__)

_WINDOWS = os.name == "nt"

#: The chord that pastes in the focused application. Wayland terminals need
#: ctrl+shift+v; on Windows that is *unformatted* paste, which most native
#: apps ignore outright — there the universal chord is plain ctrl+v.
DEFAULT_PASTE_KEY = "ctrl+v" if _WINDOWS else "ctrl+shift+v"

#: Applications whose microphone is silenced while dictating. The two platforms
#: name the same thing differently: PipeWire reports a stream's
#: ``application.name`` ("WEBRTC VoiceEngine" is Discord's mic stream), while
#: Core Audio identifies a session by the executable behind it.
DEFAULT_MUTE_APPS = ("Discord.exe",) if _WINDOWS else ("WEBRTC VoiceEngine",)

_INJECT_COMMENT = (
    """\
  # Windows pastes with ctrl+v; the clipboard route is the only one that
  # carries every language intact, so method stays clipboard here.
"""
    if _WINDOWS
    else """\
  # clipboard is the default: ydotool 1.0.4 silently truncates non-ASCII text,
  # which loses every Polish diacritic. ydotool stays available for ASCII-only use.
"""
)

_AUDIO_SOURCE_COMMENT = (
    "null = default input device" if _WINDOWS else "null = default PipeWire device"
)

_MUTE_APPS_SECTION = (
    """\
mute_apps:
  # While recording, mute these applications' microphone so people on a voice
  # chat do not hear the dictation. The physical mic stays live for voiceflow.
  # Named by executable, with or without .exe. Only apps recording through
  # WASAPI can be singled out; legacy MME/DirectSound apps are invisible.
  enabled: true
  apps: [Discord.exe]
  # Application playback (music, calls, videos) is also turned down while you
  # dictate. These values are MULTIPLIERS of each app's current volume, not
  # target levels: 0.6 means "as loud as 60% of wherever the slider already is".
  # An absolute target cannot work here — the same number is a gentle dip when
  # you listen loud and dead silence when you listen quietly.
  duck_enabled: true
  duck_to: 0.6              # apps without a rule keep 60% of their volume
  duck_rules: {}            # e.g. {Spotify.exe: 0.5, Discord.exe: 0.8}
                            # 1.0 = never duck that app
"""
    if _WINDOWS
    else """\
mute_apps:
  # While recording, mute these apps' microphone streams so people on a voice
  # chat do not hear the dictation. The physical mic stays live for voiceflow.
  # "WEBRTC VoiceEngine" is Discord's mic stream (check yours: pw-dump | grep -B2 Input/Audio).
  enabled: true
  apps: [WEBRTC VoiceEngine]
  # Additionally duck ALL application playback (music, calls, videos) while
  # you dictate. These values are MULTIPLIERS of each app's current volume, not
  # target levels: 0.6 means "as loud as 60% of wherever the slider already is".
  # An absolute target cannot work here — the same number is a gentle dip when
  # you listen loud and dead silence when you listen quietly.
  # Note the scale is the one your volume slider uses, so halving the number
  # cuts far more than half the sound power: 0.5 is roughly 18 dB down.
  duck_enabled: true
  duck_to: 0.6              # apps without a rule keep 60% of their volume
  duck_rules: {}            # e.g. {Spotify: 0.5, WEBRTC VoiceEngine: 0.8}
                            # 1.0 = never duck that app
"""
)

_HISTORY_PATH = (
    r"%LOCALAPPDATA%\voiceflow\history.jsonl"
    if _WINDOWS
    else "~/.local/share/voiceflow/history.jsonl"
)

_OVERLAY_COMMENT = (
    """\
  # On-screen indicator: a dot while listening, live text, gone when done.
  # A borderless always-on-top window marked WS_EX_NOACTIVATE, so it can never
  # steal focus from the window that should receive the paste.
"""
    if _WINDOWS
    else """\
  # On-screen indicator: a pulsing dot while listening, live text, gone when done.
  # An X11 override-redirect window, because on GNOME/Wayland a normal window
  # cannot refuse focus and would swallow the paste.
  # Drag it with the mouse to move it; double-click returns it to the default
  # spot. The position is remembered in overlay-position.json, not here.
"""
)

#: The tray indicator is a GNOME/Ayatana AppIndicator, so it exists on Linux
#: only. Emitting the section on Windows would advertise a switch with nothing
#: behind it.
_TRAY_SECTION = (
    ""
    if _WINDOWS
    else """\
tray:
  # Top-bar icon showing today's speaking time and word count; click for
  # this week/month/year. Reads from history, so history.enabled: false
  # means the icon always shows zero. Needs
  # gir1.2-ayatanaappindicator3-0.1 (installed automatically by
  # install.sh); silently absent if that package is missing.
  enabled: true
"""
)

#: The two platforms trigger a dictation through different machinery, so the
#: generated file documents only the half that is live there. Listing the other
#: half would be a setting that quietly does nothing.
_HOTKEY_SECTION = (
    """\
hotkey:
  # The global shortcut the daemon registers for itself on Windows.
  binding: ctrl+shift+space
"""
    if _WINDOWS
    else """\
hotkey:
  toggle:
    # Press to start, press again to stop. The key itself lives in the desktop's
    # own shortcut store, which is what scripts/install-hotkey.sh writes and what
    # the desktop app edits; this is the value that installer uses.
    enabled: true
    binding: <Super>g
  # push_to_talk — record only while the key is held — is NOT active yet, so it
  # is deliberately absent here: a setting that quietly does nothing is worse
  # than a missing one. The mechanism is settled and scripts/voiceflow-hotkeys.py
  # already speaks it (the GlobalShortcuts portal, the only way to see a key
  # RELEASE without giving voiceflow read access to every input device), but
  # nothing calls that script. The hold-up is not technical: binding a portal
  # shortcut makes the desktop ask for confirmation once, and that prompt was
  # judged not worth it while the toggle does the job.
"""
)

DEFAULT_CONFIG = f"""\
# voiceflow configuration
model:
  name: large-v3-turbo
  device: cuda            # cuda | cpu | auto
  compute_type: float16
  language: pl            # ISO 639-1 code; null = automatic detection
  beam_size: 5
  # Threads used when transcribing on the CPU. 0 = one per physical core, which
  # on a laptop is worth roughly a fifth of the waiting time over the four
  # threads CTranslate2 would otherwise take. Ignored on the GPU.
  cpu_threads: 0
  # Proper nouns and jargon Whisper otherwise mangles. This biases decoding only;
  # it never rewrites anything. Keep the list short — an overlong bias prompt
  # costs accuracy and can leak into the transcript.
  vocabulary: []          # e.g. [Supabase, Coolify, WooCommerce]
audio:
  source: null            # {_AUDIO_SOURCE_COMMENT}
  max_seconds: 300
{_HOTKEY_SECTION}\
inject:
{_INJECT_COMMENT}\
  method: clipboard       # clipboard | ydotool | auto
  key_delay_ms: 12
  paste_key: {DEFAULT_PASTE_KEY}
  restore_clipboard: true
preview:
  enabled: true
  interval_seconds: 1.0   # how often the live preview refreshes
  window_seconds: 30      # only the last N seconds are re-transcribed per tick
  max_chars: 330          # tail kept; roughly fills the overlay's five lines
incremental:
  # What you have already said is transcribed during the pauses, so after the
  # hotkey only the last stretch is left to wait for. The cut is made in the
  # silence between sentences, never inside one, so the text is the same as a
  # single pass would have produced.
  # The size is not a preference: Whisper's encoder always processes a 30-second
  # window, so a small piece costs a whole window's work and committing often
  # makes the total *slower*. Below min_chunk_seconds nothing is committed and
  # the recording is transcribed in one pass, exactly as before.
  enabled: true
  min_chunk_seconds: 25.0   # a piece worth its own 30 s encoder window
  min_silence_seconds: 0.7  # quiet that counts as a pause, not a breath
{_MUTE_APPS_SECTION}\
presence:
  # Discord Rich Presence: friends see "dyktuje glosem" with a timer while you
  # dictate (local IPC only, never chat messages). Register a free application
  # at discord.com/developers, name it voiceflow, paste its Application ID here.
  enabled: false
  client_id: ""
updates:
  # Once a day voiceflow asks github.com whether a newer release exists - the
  # ONLY network request the project makes. Set false to go fully offline.
  check: true
history:
  # Every dictation is logged locally ({_HISTORY_PATH})
  # so text is recoverable when a paste lands in the wrong window, and so the
  # settings app can show statistics. store_text: false keeps counts only.
  enabled: true
  store_text: true
  max_entries: 20000
overlay:
{_OVERLAY_COMMENT}\
  enabled: true
{_TRAY_SECTION}\
notifications:
  # Only used for errors now; the overlay carries the normal status.
  enabled: true
room:
  # A shared dictation room: whoever is speaking blocks the others, and their
  # speaking quietens audio on every machine in the room.
  #
  # This is the ONLY part of voiceflow that sends anything off this machine, and
  # even then only presence events and counts — words and seconds. The recording
  # and the transcribed text never leave. Off unless you join a room, and joining
  # is a command: `voiceflow room create --as YourName`.
  enabled: false
log_level: INFO
"""


@dataclass(frozen=True, slots=True)
class ModelConfig:
    """Speech recognition model settings."""

    name: str = "large-v3-turbo"
    device: str = "cuda"
    compute_type: str = "float16"
    language: str | None = "pl"
    beam_size: int = 5
    #: Computation threads when transcribing on the CPU. Zero means "decide from
    #: the machine": CTranslate2 defaults to four regardless of what is there,
    #: which leaves most of a laptop idle while the user waits for their text.
    cpu_threads: int = 0
    #: Domain terms Whisper should lean towards. Empty by default: the vocabulary
    #: is personal to whoever runs this, so it belongs in their config file rather
    #: than in the source tree.
    vocabulary: tuple[str, ...] = ()


@dataclass(frozen=True, slots=True)
class AudioConfig:
    """PipeWire recording settings."""

    source: str | None = None
    max_seconds: int = 300


@dataclass(frozen=True, slots=True)
class InjectConfig:
    """Text injection settings."""

    method: str = "clipboard"
    key_delay_ms: int = 12
    paste_key: str = DEFAULT_PASTE_KEY
    restore_clipboard: bool = True


@dataclass(frozen=True, slots=True)
class PreviewConfig:
    """Live transcription preview settings."""

    enabled: bool = True
    interval_seconds: float = 1.0
    window_seconds: float = 30.0
    max_chars: int = 330


@dataclass(frozen=True, slots=True)
class IncrementalConfig:
    """Transcribing finished sentences while the user is still dictating."""

    enabled: bool = True
    #: Nothing is committed before this much audio has piled up, and the number
    #: is dictated by Whisper rather than by taste: its encoder always processes
    #: a 30-second window, however little audio is in it. Measured on an
    #: i7-1260P, decoding 6 s of speech costs 7.6 s and decoding 29 s costs
    #: 11.8 s — so committing in small pieces does not divide the work, it
    #: multiplies it, and the wait at the end gets *longer*. A piece worth
    #: committing is therefore nearly a whole window; below that, the recording
    #: is transcribed in one pass exactly as it always was.
    min_chunk_seconds: float = 25.0
    #: How much quiet counts as a pause rather than a breath. This is where the
    #: recording gets cut, so it must be silence the speaker meant.
    min_silence_seconds: float = 0.7


@dataclass(frozen=True, slots=True)
class MuteAppsConfig:
    """Muting and ducking other applications' audio during recording."""

    enabled: bool = True
    #: Applications whose microphone is silenced while dictating: PipeWire
    #: ``application.name`` values on Linux, executable names on Windows.
    apps: tuple[str, ...] = DEFAULT_MUTE_APPS
    #: Also turn DOWN application playback (music, calls, videos) while dictating.
    duck_enabled: bool = True
    #: How much of an app's CURRENT volume is left while dictating, for apps
    #: without a rule of their own. 0.6 means "drop the slider to 60% of wherever
    #: the user had it".
    #:
    #: Relative, not absolute, and that distinction is the whole point. An
    #: absolute target behaves completely differently depending on how loud the
    #: user happens to be listening: the same "0.29" is a gentle dip for someone
    #: at full volume and total silence for someone already listening quietly.
    #: A multiplier ducks by the same amount either way.
    duck_to: float = 0.6
    #: Per-application overrides: PipeWire application.name -> multiplier.
    #: 1.0 means "never duck this app". Matched case-insensitively.
    duck_rules: tuple[tuple[str, float], ...] = ()


@dataclass(frozen=True, slots=True)
class UpdatesConfig:
    """Daily check for a newer release (the project's only network access)."""

    check: bool = True


@dataclass(frozen=True, slots=True)
class HotkeyModeConfig:
    """One way of starting a dictation, with its own key."""

    enabled: bool
    binding: str


@dataclass(frozen=True, slots=True)
class HotkeyConfig:
    """How a dictation gets triggered.

    The two Linux modes are independent and can run at once on different keys,
    because they ride on different mechanisms:

    * ``toggle`` is a gsettings custom keybinding that runs ``voiceflow toggle``.
      GNOME reports only the key *press* there, which is all a toggle needs.
    * ``push_to_talk`` goes through the GlobalShortcuts portal, the only route
      that reports the key *release* as well — and the only one that does not
      require handing voiceflow read access to every input device.

    Giving both modes the same key is rejected rather than guessed at: telling
    a tap from a hold would mean a timing threshold, and a dictation tool that
    behaves differently depending on how fast you let go is worse than one that
    refuses the ambiguous configuration.
    """

    #: Windows only: the daemon registers this one itself via RegisterHotKey.
    binding: str = "ctrl+shift+space"
    toggle: HotkeyModeConfig = field(
        default_factory=lambda: HotkeyModeConfig(True, "<Super>g")
    )
    #: Not <Super>space, which GNOME ships bound to switch-input-source — the
    #: keyboard layout switch. A default that silently steals a system shortcut
    #: is a bug report waiting to happen. <Control><Alt>space is unclaimed on a
    #: stock GNOME and comfortable to hold down with one hand.
    push_to_talk: HotkeyModeConfig = field(
        default_factory=lambda: HotkeyModeConfig(False, "<Control><Alt>space")
    )


@dataclass(frozen=True, slots=True)
class PresenceConfig:
    """Discord Rich Presence while dictating."""

    enabled: bool = False
    #: Application id from discord.com/developers — it determines the shown name.
    client_id: str = ""


@dataclass(frozen=True, slots=True)
class HistoryConfig:
    """Persistent dictation history (retrieval + statistics)."""

    enabled: bool = True
    #: Store the transcribed text itself. Disable if you dictate sensitive
    #: content; word counts (statistics) are kept either way.
    store_text: bool = True
    max_entries: int = 20000


@dataclass(frozen=True, slots=True)
class OverlayConfig:
    """On-screen indicator settings."""

    enabled: bool = True


@dataclass(frozen=True, slots=True)
class TrayConfig:
    """GNOME top-bar dictation-stats indicator settings."""

    enabled: bool = True


@dataclass(frozen=True, slots=True)
class RoomConfig:
    """Shared dictation room. Off unless somebody deliberately joins one.

    This is the only part of voiceflow that sends anything off the machine, and
    even then only presence events and counts — never audio, never the text.
    It stays opt-in for exactly that reason.
    """

    enabled: bool = False
    #: e.g. wss://rooms.pbdevs.com
    server: str = ""
    #: Six-character room code, case-insensitive.
    code: str = ""
    #: Device token from POST /api/devices.
    token: str = ""
    #: Whether somebody else speaking may quieten audio here. A permission,
    #: not a side effect of being in the room.
    duck_for_others: bool = True
    #: Czy pokój widzi, czego słuchasz. Osobna zgoda, bo to jest coś o Tobie,
    #: a nie o pracy — wejście do pokoju samo w sobie jej nie daje.
    share_music: bool = True
    #: Czy pokój widzi Twoje zużycie Claude Code. Domyślnie TAK (decyzja
    #: Filipa 2026-08-14): kto siedzi z kimś w pokoju, ten gra w otwarte
    #: karty — a kto nie chce, wyłącza to u siebie jednym przełącznikiem.
    share_claude_usage: bool = True


@dataclass(frozen=True, slots=True)
class NotificationsConfig:
    """Desktop notification settings."""

    enabled: bool = True


@dataclass(frozen=True, slots=True)
class Config:
    """Complete voiceflow configuration."""

    model: ModelConfig = field(default_factory=ModelConfig)
    audio: AudioConfig = field(default_factory=AudioConfig)
    inject: InjectConfig = field(default_factory=InjectConfig)
    preview: PreviewConfig = field(default_factory=PreviewConfig)
    incremental: IncrementalConfig = field(default_factory=IncrementalConfig)
    mute_apps: MuteAppsConfig = field(default_factory=MuteAppsConfig)
    history: HistoryConfig = field(default_factory=HistoryConfig)
    presence: PresenceConfig = field(default_factory=PresenceConfig)
    hotkey: HotkeyConfig = field(default_factory=HotkeyConfig)
    updates: UpdatesConfig = field(default_factory=UpdatesConfig)
    overlay: OverlayConfig = field(default_factory=OverlayConfig)
    tray: TrayConfig = field(default_factory=TrayConfig)
    notifications: NotificationsConfig = field(default_factory=NotificationsConfig)
    room: RoomConfig = field(default_factory=RoomConfig)
    log_level: str = "INFO"


_SCHEMA: dict[str, set[str] | None] = {
    "model": {
        "name",
        "device",
        "compute_type",
        "language",
        "beam_size",
        "cpu_threads",
        "vocabulary",
    },
    "audio": {"source", "max_seconds"},
    "inject": {"method", "key_delay_ms", "paste_key", "restore_clipboard"},
    "preview": {"enabled", "interval_seconds", "window_seconds", "max_chars"},
    "incremental": {"enabled", "min_chunk_seconds", "min_silence_seconds"},
    "mute_apps": {"enabled", "apps", "duck_enabled", "duck_to", "duck_rules"},
    "history": {"enabled", "store_text", "max_entries"},
    "presence": {"enabled", "client_id"},
    "hotkey": {"binding", "toggle", "push_to_talk"},
    "updates": {"check"},
    "overlay": {"enabled"},
    "tray": {"enabled"},
    "notifications": {"enabled"},
    "room": {
        "enabled", "server", "code", "token", "duck_for_others",
        "share_music", "share_claude_usage",
    },
    "log_level": None,
}


def _section(data: Mapping[str, Any], name: str) -> Mapping[str, Any]:
    value = data.get(name, {})
    if not isinstance(value, Mapping):
        LOGGER.warning("Sekcja konfiguracji '%s' nie jest mapą; używam wartości domyślnych", name)
        return {}
    return value


def _warn_unknown(data: Mapping[str, Any]) -> None:
    for key in data:
        if key not in _SCHEMA:
            LOGGER.warning("Nieznany klucz konfiguracji: %s", key)
    for section, allowed in _SCHEMA.items():
        if allowed is None:
            continue
        values = data.get(section)
        if isinstance(values, Mapping):
            for key in values:
                if key not in allowed:
                    LOGGER.warning("Nieznany klucz konfiguracji: %s.%s", section, key)


def _choice(value: Any, allowed: set[str], default: str, path: str) -> str:
    if isinstance(value, str) and value in allowed:
        return value
    LOGGER.warning("Nieprawidłowa wartość %s=%r; używam %s", path, value, default)
    return default


def _positive_int(value: Any, default: int, path: str) -> int:
    if isinstance(value, int) and not isinstance(value, bool) and value > 0:
        return value
    LOGGER.warning("Nieprawidłowa wartość %s=%r; używam %d", path, value, default)
    return default


def _non_negative_int(value: Any, default: int, path: str) -> int:
    """Like ``_positive_int``, but zero is a legitimate answer — it means auto."""
    if isinstance(value, int) and not isinstance(value, bool) and value >= 0:
        return value
    LOGGER.warning("Nieprawidłowa wartość %s=%r; używam %d", path, value, default)
    return default


def _positive_float(value: Any, default: float, path: str) -> float:
    if isinstance(value, (int, float)) and not isinstance(value, bool) and value > 0:
        return float(value)
    LOGGER.warning("Nieprawidłowa wartość %s=%r; używam %s", path, value, default)
    return default


def _fraction(value: Any, default: float, path: str) -> float:
    """A volume fraction: 0.0 (silence) through 1.0 (untouched)."""
    if isinstance(value, (int, float)) and not isinstance(value, bool) and 0.0 <= float(value) <= 1.0:
        return float(value)
    LOGGER.warning("Nieprawidłowa wartość %s=%r; używam %s", path, value, default)
    return default


def _boolean(value: Any, default: bool, path: str) -> bool:
    if isinstance(value, bool):
        return value
    LOGGER.warning("Nieprawidłowa wartość %s=%r; używam %s", path, value, default)
    return default


def _string_tuple(value: Any, path: str) -> tuple[str, ...]:
    """Accept a YAML list of strings, dropping anything that is not one."""
    if value is None:
        return ()
    if isinstance(value, str):
        # A bare string is a plausible mistake; treat it as a single-item list.
        return (value.strip(),) if value.strip() else ()
    if not isinstance(value, (list, tuple)):
        LOGGER.warning("Nieprawidłowa wartość %s=%r; używam pustej listy", path, value)
        return ()
    terms: list[str] = []
    for item in value:
        if isinstance(item, str) and item.strip():
            terms.append(item.strip())
        else:
            LOGGER.warning("Pomijam nieprawidłowy element %s: %r", path, item)
    return tuple(terms)


def _duck_to(mute_apps: Mapping[str, Any]) -> float:
    """Read the ducking multiplier, shouting about the renamed old setting.

    ``duck_volume`` used to be an absolute target: "set the app to 0.4". It is
    now ``duck_to``, a multiplier of the app's own level. Reusing the old name
    would have been worse than renaming it — the numbers look identical and the
    behaviour is not, so an untouched config would have quietly started ducking
    by a different amount with nothing to explain why.
    """
    if "duck_volume" in mute_apps:
        LOGGER.warning(
            "mute_apps.duck_volume już nie istnieje — zastąpiło je mute_apps.duck_to, "
            "które jest MNOŻNIKIEM obecnej głośności aplikacji, a nie poziomem "
            "docelowym. Twoja stara wartość (%r) jest ignorowana; ustaw duck_to "
            "(np. 0.6 = ścisz do 60%% obecnej głośności).",
            mute_apps.get("duck_volume"),
        )
    return _fraction(mute_apps.get("duck_to", 0.6), 0.6, "mute_apps.duck_to")


def _hotkey_mode(
    data: Mapping[str, Any], name: str, default: HotkeyModeConfig, path: str
) -> HotkeyModeConfig:
    """Parse one trigger mode, falling back to its defaults field by field."""
    section = data.get(name)
    if section is None:
        return default
    if not isinstance(section, Mapping):
        LOGGER.warning("Sekcja %s nie jest mapą; używam wartości domyślnych", path)
        return default
    for key in section:
        if key not in ("enabled", "binding"):
            LOGGER.warning("Nieznany klucz konfiguracji: %s.%s", path, key)
    binding = section.get("binding", default.binding)
    if not isinstance(binding, str) or not binding.strip():
        LOGGER.warning(
            "Nieprawidłowa wartość %s.binding=%r; używam %s", path, binding, default.binding
        )
        binding = default.binding
    return HotkeyModeConfig(
        enabled=_boolean(section.get("enabled", default.enabled), default.enabled, f"{path}.enabled"),
        binding=binding.strip(),
    )


def _hotkey_config(data: Mapping[str, Any]) -> HotkeyConfig:
    """Parse the hotkey section, refusing a binding claimed by both modes."""
    defaults = HotkeyConfig()
    binding = data.get("binding", defaults.binding)
    toggle = _hotkey_mode(data, "toggle", defaults.toggle, "hotkey.toggle")
    push_to_talk = _hotkey_mode(data, "push_to_talk", defaults.push_to_talk, "hotkey.push_to_talk")
    if (
        toggle.enabled
        and push_to_talk.enabled
        and toggle.binding.casefold() == push_to_talk.binding.casefold()
    ):
        # Both modes on one key would need a hold-versus-tap timer, and a
        # dictation tool whose behaviour depends on how fast you release is
        # worse than one that says no. Push-to-talk yields: the toggle is what
        # every existing installation already relies on.
        LOGGER.warning(
            "hotkey.toggle i hotkey.push_to_talk mają ten sam skrót (%s); "
            "wyłączam push_to_talk — przypisz mu inny klawisz",
            toggle.binding,
        )
        push_to_talk = HotkeyModeConfig(False, push_to_talk.binding)
    return HotkeyConfig(
        binding=str(binding or defaults.binding),
        toggle=toggle,
        push_to_talk=push_to_talk,
    )


def _duck_rules(value: Any, path: str) -> tuple[tuple[str, float], ...]:
    """Accept a YAML mapping of app name -> volume fraction (clamped to 0..1)."""
    if value is None:
        return ()
    if not isinstance(value, Mapping):
        LOGGER.warning("Nieprawidłowa wartość %s=%r; używam pustej mapy", path, value)
        return ()
    rules: list[tuple[str, float]] = []
    for name, volume in value.items():
        if not isinstance(name, str) or not name.strip():
            LOGGER.warning("Pomijam nieprawidłowy klucz %s: %r", path, name)
            continue
        if not isinstance(volume, (int, float)) or isinstance(volume, bool):
            LOGGER.warning("Pomijam nieprawidłową głośność %s[%s]=%r", path, name, volume)
            continue
        rules.append((name.strip(), min(max(float(volume), 0.0), 1.0)))
    return tuple(rules)


def parse_config(data: Mapping[str, Any] | None) -> Config:
    """Parse a mapping, filling missing or invalid fields with defaults."""
    root: Mapping[str, Any] = data or {}
    _warn_unknown(root)
    model = _section(root, "model")
    audio = _section(root, "audio")
    inject = _section(root, "inject")
    preview = _section(root, "preview")
    incremental = _section(root, "incremental")
    mute_apps = _section(root, "mute_apps")
    history = _section(root, "history")
    presence = _section(root, "presence")
    hotkey = _section(root, "hotkey")
    updates = _section(root, "updates")
    overlay = _section(root, "overlay")
    tray = _section(root, "tray")
    notifications = _section(root, "notifications")
    room = _section(root, "room")

    language = model.get("language", "pl")
    if language is not None and not isinstance(language, str):
        LOGGER.warning("Nieprawidłowa wartość model.language=%r; używam pl", language)
        language = "pl"

    source = audio.get("source")
    if source is not None and not isinstance(source, str):
        LOGGER.warning("Nieprawidłowa wartość audio.source=%r; używam null", source)
        source = None

    name = model.get("name", "large-v3-turbo")
    compute_type = model.get("compute_type", "float16")
    paste_key = inject.get("paste_key", DEFAULT_PASTE_KEY)
    log_level = root.get("log_level", "INFO")
    return Config(
        model=ModelConfig(
            name=name if isinstance(name, str) and name else "large-v3-turbo",
            device=_choice(model.get("device", "cuda"), {"cuda", "cpu", "auto"}, "cuda", "model.device"),
            compute_type=compute_type if isinstance(compute_type, str) and compute_type else "float16",
            language=language,
            beam_size=_positive_int(model.get("beam_size", 5), 5, "model.beam_size"),
            cpu_threads=_non_negative_int(model.get("cpu_threads", 0), 0, "model.cpu_threads"),
            vocabulary=_string_tuple(model.get("vocabulary"), "model.vocabulary"),
        ),
        audio=AudioConfig(
            source=source,
            max_seconds=_positive_int(audio.get("max_seconds", 300), 300, "audio.max_seconds"),
        ),
        inject=InjectConfig(
            method=_choice(inject.get("method", "clipboard"), {"ydotool", "clipboard", "auto"}, "clipboard", "inject.method"),
            key_delay_ms=_positive_int(inject.get("key_delay_ms", 12), 12, "inject.key_delay_ms"),
            paste_key=paste_key if isinstance(paste_key, str) and paste_key else DEFAULT_PASTE_KEY,
            restore_clipboard=_boolean(inject.get("restore_clipboard", True), True, "inject.restore_clipboard"),
        ),
        preview=PreviewConfig(
            enabled=_boolean(preview.get("enabled", True), True, "preview.enabled"),
            interval_seconds=_positive_float(preview.get("interval_seconds", 1.0), 1.0, "preview.interval_seconds"),
            window_seconds=_positive_float(preview.get("window_seconds", 30.0), 30.0, "preview.window_seconds"),
            max_chars=_positive_int(preview.get("max_chars", 330), 330, "preview.max_chars"),
        ),
        incremental=IncrementalConfig(
            enabled=_boolean(incremental.get("enabled", True), True, "incremental.enabled"),
            min_chunk_seconds=_positive_float(
                incremental.get("min_chunk_seconds", 25.0), 25.0, "incremental.min_chunk_seconds"
            ),
            min_silence_seconds=_positive_float(
                incremental.get("min_silence_seconds", 0.7), 0.7, "incremental.min_silence_seconds"
            ),
        ),
        mute_apps=MuteAppsConfig(
            enabled=_boolean(mute_apps.get("enabled", True), True, "mute_apps.enabled"),
            apps=_string_tuple(mute_apps.get("apps", DEFAULT_MUTE_APPS), "mute_apps.apps"),
            duck_enabled=_boolean(mute_apps.get("duck_enabled", True), True, "mute_apps.duck_enabled"),
            duck_to=_duck_to(mute_apps),
            duck_rules=_duck_rules(mute_apps.get("duck_rules"), "mute_apps.duck_rules"),
        ),
        history=HistoryConfig(
            enabled=_boolean(history.get("enabled", True), True, "history.enabled"),
            store_text=_boolean(history.get("store_text", True), True, "history.store_text"),
            max_entries=_positive_int(history.get("max_entries", 20000), 20000, "history.max_entries"),
        ),
        presence=PresenceConfig(
            enabled=_boolean(presence.get("enabled", False), False, "presence.enabled"),
            client_id=str(presence.get("client_id", "") or ""),
        ),
        hotkey=_hotkey_config(hotkey),
        updates=UpdatesConfig(
            check=_boolean(updates.get("check", True), True, "updates.check"),
        ),
        overlay=OverlayConfig(
            enabled=_boolean(overlay.get("enabled", True), True, "overlay.enabled"),
        ),
        tray=TrayConfig(
            enabled=_boolean(tray.get("enabled", True), True, "tray.enabled"),
        ),
        notifications=NotificationsConfig(
            enabled=notifications.get("enabled", True) if isinstance(notifications.get("enabled", True), bool) else True,
        ),
        room=RoomConfig(
            enabled=_boolean(room.get("enabled", False), False, "room.enabled"),
            server=str(room.get("server", "") or "").strip(),
            code=str(room.get("code", "") or "").strip().upper(),
            token=str(room.get("token", "") or "").strip(),
            duck_for_others=_boolean(
                room.get("duck_for_others", True), True, "room.duck_for_others"
            ),
            share_music=_boolean(room.get("share_music", True), True, "room.share_music"),
            share_claude_usage=_boolean(
                room.get("share_claude_usage", True), True, "room.share_claude_usage"
            ),
        ),
        log_level=log_level.upper() if isinstance(log_level, str) else "INFO",
    )


def load_config(path: Path | None = None) -> Config:
    """Load configuration, creating a commented default file on first use."""
    target = path or config_dir() / "config.yaml"
    if not target.exists():
        target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        target.write_text(DEFAULT_CONFIG, encoding="utf-8")
        LOGGER.info("Utworzono domyślną konfigurację: %s", target)
    try:
        loaded = yaml.safe_load(target.read_text(encoding="utf-8"))
    except (OSError, yaml.YAMLError) as exc:
        raise RuntimeError(f"Nie można wczytać konfiguracji {target}: {exc}") from exc
    if loaded is not None and not isinstance(loaded, Mapping):
        LOGGER.warning("Główny element konfiguracji nie jest mapą; używam wartości domyślnych")
        loaded = {}
    return parse_config(loaded)

