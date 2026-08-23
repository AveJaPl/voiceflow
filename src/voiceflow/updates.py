"""Once-a-day update check against GitHub releases.

The only network access in the entire project, so it is deliberately narrow
and honest: one anonymous GET to the public releases endpoint, at most once a
day (cached in the data directory), fully disabled by ``updates.check: false``.
Nothing about the user is sent — GitHub sees a plain API request.

Releases are per-platform, and that is what the check has to respect. macOS
ships a packaged build tagged ``mac-v0.6.0``; every other platform runs the
source release tagged ``v0.5.0``. Asking GitHub for *the latest release* returns
whichever was published last regardless of platform, and ``parse_version`` reads
only the digits — so a mac build published after the last source release
announced itself to Linux as version 0.6.0 over 0.5.0, an update that does not
exist and cannot be installed. The newest release **for this platform** is what
matters, so the list endpoint is filtered rather than the latest one trusted.
"""

from __future__ import annotations

import json
import logging
import re
import sys
import time
import urllib.request
from dataclasses import dataclass
from pathlib import Path

from voiceflow.config import UpdatesConfig
from voiceflow.paths import data_dir

LOGGER = logging.getLogger(__name__)

#: Lista, nie /latest: /latest zwraca ostatnio opublikowane wydanie niezależnie
#: od platformy, a nas interesuje najnowsze wydanie DLA TEJ platformy.
RELEASES_API = "https://api.github.com/repos/AveJaPl/voiceflow/releases?per_page=30"
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


def release_prefix() -> str:
    """Tag prefix marking releases built for the platform we are running on."""
    return "mac-" if sys.platform == "darwin" else ""


def tag_matches_platform(tag: str, prefix: str | None = None) -> bool:
    """True when ``tag`` names a release meant for this platform."""
    marker = release_prefix() if prefix is None else prefix
    if marker:
        return tag.startswith(marker)
    # No prefix for this platform means the tag must open with the version
    # itself, so a build tagged for a different one is never mistaken for ours.
    return re.match(r"^v?\d", tag) is not None


def strip_prefix(tag: str, prefix: str | None = None) -> str:
    """Return the bare version inside a platform tag (``mac-v0.6.0`` -> ``v0.6.0``)."""
    marker = release_prefix() if prefix is None else prefix
    return tag[len(marker):] if marker and tag.startswith(marker) else tag


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
    """Ask GitHub for the newest release built for this platform.

    Returns (version, html url), with any platform prefix already stripped so
    the caller compares and displays a plain version. None when the request
    fails or the repository has no release for this platform at all — silence
    beats announcing an update the user cannot install.
    """
    request = urllib.request.Request(
        RELEASES_API, headers={"User-Agent": "voiceflow-update-check"}
    )
    try:
        with urllib.request.urlopen(request, timeout=_TIMEOUT) as response:
            data = json.loads(response.read().decode("utf-8"))
    except Exception as exc:
        LOGGER.debug("Sprawdzenie aktualizacji nie powiodło się: %s", exc)
        return None
    if not isinstance(data, list):
        return None
    prefix = release_prefix()
    best: tuple[tuple[int, ...], str, str] | None = None
    for entry in data:
        if not isinstance(entry, dict) or entry.get("draft") or entry.get("prerelease"):
            continue
        tag = entry.get("tag_name")
        if not isinstance(tag, str) or not tag or not tag_matches_platform(tag, prefix):
            continue
        version = strip_prefix(tag, prefix)
        url = entry.get("html_url") if isinstance(entry.get("html_url"), str) else RELEASES_URL
        candidate = (parse_version(version), version, url)
        if best is None or candidate[0] > best[0]:
            best = candidate
    if best is None:
        LOGGER.debug("Brak wydań dla tej platformy (przedrostek %r)", prefix)
        return None
    return best[1], best[2]


def check(config: UpdatesConfig, *, force: bool = False, now: float | None = None) -> UpdateInfo | None:
    """Daily-throttled check. Returns None when disabled, throttled, or offline."""
    if not config.check and not force:
        return None
    moment = time.time() if now is None else now
    cached = _read_cache()
    if not force and cached and moment - float(cached.get("checked_at", 0)) < _CACHE_SECONDS:
        latest = str(cached.get("latest", ""))
        url = str(cached.get("url", RELEASES_URL))
        if not latest or not tag_matches_platform(latest):
            # An older build of this module cached whatever GitHub called the
            # latest release, foreign platforms included. Treating that as "no
            # answer" heals the stale entry instead of repeating its verdict
            # for another day.
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
