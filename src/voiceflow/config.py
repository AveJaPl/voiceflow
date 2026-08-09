"""Typed configuration loading and default file creation."""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Mapping

import yaml

from voiceflow.paths import config_dir

LOGGER = logging.getLogger(__name__)

DEFAULT_CONFIG = """\
# voiceflow configuration
model:
  name: large-v3-turbo
  device: cuda            # cuda | cpu | auto
  compute_type: float16
  language: pl            # ISO 639-1 code; null = automatic detection
  beam_size: 5
  # Proper nouns and jargon Whisper otherwise mangles. This biases decoding only;
  # it never rewrites anything. Keep the list short — an overlong bias prompt
  # costs accuracy and can leak into the transcript.
  vocabulary: []          # e.g. [Supabase, Coolify, WooCommerce]
audio:
  source: null            # null = default PipeWire device
  max_seconds: 300
inject:
  # clipboard is the default: ydotool 1.0.4 silently truncates non-ASCII text,
  # which loses every Polish diacritic. ydotool stays available for ASCII-only use.
  method: clipboard       # clipboard | ydotool | auto
  key_delay_ms: 12
  paste_key: ctrl+shift+v
  restore_clipboard: true
preview:
  enabled: true
  interval_seconds: 1.0   # how often the live preview refreshes
  window_seconds: 30      # only the last N seconds are re-transcribed per tick
  max_chars: 330          # tail kept; roughly fills the overlay's five lines
mute_apps:
  # While recording, mute these apps' microphone streams so people on a voice
  # chat do not hear the dictation. The physical mic stays live for voiceflow.
  # "WEBRTC VoiceEngine" is Discord's mic stream (check yours: pw-dump | grep -B2 Input/Audio).
  enabled: true
  apps: [WEBRTC VoiceEngine]
  # Additionally duck ALL application playback (music, calls, videos) while
  # you dictate. duck_volume is the default target; duck_rules overrides it
  # per app (PipeWire application.name; 1.0 = never duck that app).
  duck_enabled: true
  duck_volume: 0.4          # apps without a rule duck to 40%
  duck_rules: {}            # e.g. {Spotify: 0.2, WEBRTC VoiceEngine: 0.3}
history:
  # Every dictation is logged locally (~/.local/share/voiceflow/history.jsonl)
  # so text is recoverable when a paste lands in the wrong window, and so the
  # settings app can show statistics. store_text: false keeps counts only.
  enabled: true
  store_text: true
  max_entries: 20000
overlay:
  # On-screen indicator: a pulsing dot while listening, live text, gone when done.
  # An X11 override-redirect window, because on GNOME/Wayland a normal window
  # cannot refuse focus and would swallow the paste.
  enabled: true
notifications:
  # Only used for errors now; the overlay carries the normal status.
  enabled: true
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
    paste_key: str = "ctrl+shift+v"
    restore_clipboard: bool = True


@dataclass(frozen=True, slots=True)
class PreviewConfig:
    """Live transcription preview settings."""

    enabled: bool = True
    interval_seconds: float = 1.0
    window_seconds: float = 30.0
    max_chars: int = 330


@dataclass(frozen=True, slots=True)
class MuteAppsConfig:
    """Muting and ducking other applications' audio during recording."""

    enabled: bool = True
    #: application.name values of PipeWire capture streams to silence.
    #: "WEBRTC VoiceEngine" is Discord's microphone stream.
    apps: tuple[str, ...] = ("WEBRTC VoiceEngine",)
    #: Also turn DOWN application playback (music, calls, videos) while dictating.
    duck_enabled: bool = True
    #: Default duck target for apps WITHOUT a specific rule, as a fraction of
    #: full volume. 0.4 means "duck to 40%", i.e. 60% quieter.
    duck_volume: float = 0.4
    #: Per-application overrides: PipeWire application.name -> target volume.
    #: 1.0 means "never duck this app". Matched case-insensitively.
    duck_rules: tuple[tuple[str, float], ...] = ()


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
    mute_apps: MuteAppsConfig = field(default_factory=MuteAppsConfig)
    history: HistoryConfig = field(default_factory=HistoryConfig)
    overlay: OverlayConfig = field(default_factory=OverlayConfig)
    notifications: NotificationsConfig = field(default_factory=NotificationsConfig)
    log_level: str = "INFO"


_SCHEMA: dict[str, set[str] | None] = {
    "model": {"name", "device", "compute_type", "language", "beam_size", "vocabulary"},
    "audio": {"source", "max_seconds"},
    "inject": {"method", "key_delay_ms", "paste_key", "restore_clipboard"},
    "preview": {"enabled", "interval_seconds", "window_seconds", "max_chars"},
    "mute_apps": {"enabled", "apps", "duck_enabled", "duck_volume", "duck_rules"},
    "history": {"enabled", "store_text", "max_entries"},
    "overlay": {"enabled"},
    "notifications": {"enabled"},
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


def _positive_float(value: Any, default: float, path: str) -> float:
    if isinstance(value, (int, float)) and not isinstance(value, bool) and value > 0:
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
    mute_apps = _section(root, "mute_apps")
    history = _section(root, "history")
    overlay = _section(root, "overlay")
    notifications = _section(root, "notifications")

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
    paste_key = inject.get("paste_key", "ctrl+shift+v")
    log_level = root.get("log_level", "INFO")
    return Config(
        model=ModelConfig(
            name=name if isinstance(name, str) and name else "large-v3-turbo",
            device=_choice(model.get("device", "cuda"), {"cuda", "cpu", "auto"}, "cuda", "model.device"),
            compute_type=compute_type if isinstance(compute_type, str) and compute_type else "float16",
            language=language,
            beam_size=_positive_int(model.get("beam_size", 5), 5, "model.beam_size"),
            vocabulary=_string_tuple(model.get("vocabulary"), "model.vocabulary"),
        ),
        audio=AudioConfig(
            source=source,
            max_seconds=_positive_int(audio.get("max_seconds", 300), 300, "audio.max_seconds"),
        ),
        inject=InjectConfig(
            method=_choice(inject.get("method", "clipboard"), {"ydotool", "clipboard", "auto"}, "clipboard", "inject.method"),
            key_delay_ms=_positive_int(inject.get("key_delay_ms", 12), 12, "inject.key_delay_ms"),
            paste_key=paste_key if isinstance(paste_key, str) and paste_key else "ctrl+shift+v",
            restore_clipboard=_boolean(inject.get("restore_clipboard", True), True, "inject.restore_clipboard"),
        ),
        preview=PreviewConfig(
            enabled=_boolean(preview.get("enabled", True), True, "preview.enabled"),
            interval_seconds=_positive_float(preview.get("interval_seconds", 1.0), 1.0, "preview.interval_seconds"),
            window_seconds=_positive_float(preview.get("window_seconds", 30.0), 30.0, "preview.window_seconds"),
            max_chars=_positive_int(preview.get("max_chars", 330), 330, "preview.max_chars"),
        ),
        mute_apps=MuteAppsConfig(
            enabled=_boolean(mute_apps.get("enabled", True), True, "mute_apps.enabled"),
            apps=_string_tuple(mute_apps.get("apps", ("WEBRTC VoiceEngine",)), "mute_apps.apps"),
            duck_enabled=_boolean(mute_apps.get("duck_enabled", True), True, "mute_apps.duck_enabled"),
            duck_volume=_positive_float(mute_apps.get("duck_volume", 0.4), 0.4, "mute_apps.duck_volume"),
            duck_rules=_duck_rules(mute_apps.get("duck_rules"), "mute_apps.duck_rules"),
        ),
        history=HistoryConfig(
            enabled=_boolean(history.get("enabled", True), True, "history.enabled"),
            store_text=_boolean(history.get("store_text", True), True, "history.store_text"),
            max_entries=_positive_int(history.get("max_entries", 20000), 20000, "history.max_entries"),
        ),
        overlay=OverlayConfig(
            enabled=_boolean(overlay.get("enabled", True), True, "overlay.enabled"),
        ),
        notifications=NotificationsConfig(
            enabled=notifications.get("enabled", True) if isinstance(notifications.get("enabled", True), bool) else True,
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

