"""Once-a-day update check against GitHub releases.

The only network access in the entire project, so it is deliberately narrow
and honest: one anonymous GET to the public releases endpoint, at most once a
day (cached in the data directory), fully disabled by ``updates.check: false``.
Nothing about the user is sent — GitHub sees a plain API request.
"""

from __future__ import annotations

import json
import logging
import time
import urllib.request
from dataclasses import dataclass
from pathlib import Path

from voiceflow.config import UpdatesConfig
from voiceflow.paths import data_dir

LOGGER = logging.getLogger(__name__)

RELEASES_API = "https://api.github.com/repos/AveJaPl/voiceflow/releases/latest"
RELEASES_URL = "https://github.com/AveJaPl/voiceflow/releases/latest"
_CACHE_SECONDS = 24 * 3600
_TIMEOUT = 5.0


@dataclass(frozen=True, slots=True)
class UpdateInfo:
    """Result of a check: the newest published version and where to read notes."""

    latest: str
    url: str
    newer: bool


def installed_version() -> str:
    """Version of the running code, straight from package metadata."""
    try:
        from importlib.metadata import version

        return version("voiceflow")
    except Exception:  # pragma: no cover - metadata missing in odd setups
        return "0.0.0"


def parse_version(text: str) -> tuple[int, ...]:
    """Turn ``v0.2.1`` into a comparable tuple, tolerating junk suffixes."""
    parts: list[int] = []
    for chunk in text.strip().lstrip("vV").split("."):
        digits = "".join(ch for ch in chunk if ch.isdigit())
        if not digits:
            break
        parts.append(int(digits))
    return tuple(parts) or (0,)


def is_newer(candidate: str, current: str) -> bool:
    """True when ``candidate`` is a strictly newer version than ``current``."""
    return parse_version(candidate) > parse_version(current)


def _cache_file() -> Path:
    return data_dir() / "update-check.json"


def _read_cache() -> dict | None:
    try:
        data = json.loads(_cache_file().read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else None
    except (OSError, json.JSONDecodeError):
        return None


def _write_cache(payload: dict) -> None:
    try:
        _cache_file().parent.mkdir(parents=True, exist_ok=True)
        _cache_file().write_text(json.dumps(payload), encoding="utf-8")
    except OSError as exc:
        LOGGER.debug("Nie można zapisać cache aktualizacji: %s", exc)


def fetch_latest_version() -> tuple[str, str] | None:
    """Ask GitHub for the newest release tag. Returns (version, html url)."""
    request = urllib.request.Request(
        RELEASES_API, headers={"User-Agent": "voiceflow-update-check"}
    )
    try:
        with urllib.request.urlopen(request, timeout=_TIMEOUT) as response:
            data = json.loads(response.read().decode("utf-8"))
    except Exception as exc:
        LOGGER.debug("Sprawdzenie aktualizacji nie powiodło się: %s", exc)
        return None
    tag = data.get("tag_name")
    if not isinstance(tag, str) or not tag:
        return None
    url = data.get("html_url") if isinstance(data.get("html_url"), str) else RELEASES_URL
    return tag, url


def check(config: UpdatesConfig, *, force: bool = False, now: float | None = None) -> UpdateInfo | None:
    """Daily-throttled check. Returns None when disabled, throttled, or offline."""
    if not config.check and not force:
        return None
    moment = time.time() if now is None else now
    cached = _read_cache()
    if not force and cached and moment - float(cached.get("checked_at", 0)) < _CACHE_SECONDS:
        latest = str(cached.get("latest", ""))
        url = str(cached.get("url", RELEASES_URL))
        if not latest:
            return None
        return UpdateInfo(latest, url, is_newer(latest, installed_version()))
    fetched = fetch_latest_version()
    if fetched is None:
        # Cache the failure too, so an offline machine retries daily, not constantly.
        _write_cache({"checked_at": moment, "latest": "", "url": RELEASES_URL})
        return None
    latest, url = fetched
    _write_cache({"checked_at": moment, "latest": latest, "url": url})
    return UpdateInfo(latest, url, is_newer(latest, installed_version()))
