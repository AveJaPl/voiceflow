"""How much of the Claude Code limits this machine has burned through.

Read from `~/.claude/statusline-last.json`, the snapshot Claude Code writes for
its own status line. Only the two percentages and their reset times are taken —
never the session name, the working directory, the cost in dollars or anything
that could say what the person was working on.

Sharing this with a room is **off by default** (`room.share_claude_usage`).
It is more personal than a word count: it says something about how somebody
works, not about what the room produced together.

Like the now-playing tile, the value travels over the room WebSocket and is
never stored — there is no table for it.
"""

from __future__ import annotations

import json
import logging
import time
from dataclasses import dataclass
from pathlib import Path

LOGGER = logging.getLogger(__name__)

#: Po tylu godzinach snapshot przestaje mówić cokolwiek o „teraz". Pokazanie go
#: dalej byłoby podaniem starej liczby jako bieżącej.
STALE_AFTER_SECONDS = 6 * 3600


def statusline_file() -> Path:
    return Path.home() / ".claude" / "statusline-last.json"


@dataclass(frozen=True)
class ClaudeUsage:
    """The two limit windows Claude Code reports, as whole percentages."""

    five_hour: int
    seven_day: int
    #: Kiedy odnawia się okno pięciogodzinne, sekundy epoki; 0 gdy nieznane.
    resets_at: int = 0

    def as_payload(self) -> dict[str, int]:
        return {
            "fiveHour": self.five_hour,
            "sevenDay": self.seven_day,
            "resetsAt": self.resets_at,
        }


def _percentage(value: object) -> int | None:
    if not isinstance(value, (int, float)):
        return None
    return max(0, min(100, round(float(value))))


def parse(document: object, *, age_seconds: float = 0.0) -> ClaudeUsage | None:
    """Pull the two percentages out of a status-line snapshot.

    Returns None for anything unusable — a missing section, a stale file, a
    shape that changed in a Claude Code update. A tile that is absent is honest;
    a tile showing yesterday's number as today's is not.
    """
    if age_seconds > STALE_AFTER_SECONDS:
        return None
    if not isinstance(document, dict):
        return None
    limits = document.get("rate_limits")
    if not isinstance(limits, dict):
        return None
    five = limits.get("five_hour") if isinstance(limits.get("five_hour"), dict) else {}
    seven = limits.get("seven_day") if isinstance(limits.get("seven_day"), dict) else {}
    five_hour = _percentage(five.get("used_percentage"))
    seven_day = _percentage(seven.get("used_percentage"))
    if five_hour is None and seven_day is None:
        return None
    resets = five.get("resets_at")
    return ClaudeUsage(
        five_hour=five_hour or 0,
        seven_day=seven_day or 0,
        resets_at=int(resets) if isinstance(resets, (int, float)) else 0,
    )


def current_usage(path: Path | None = None) -> ClaudeUsage | None:
    """Read this machine's Claude Code limit usage, or None.

    Never raises: a missing file means Claude Code was never run here, and that
    is not an error worth a log line on every poll.
    """
    target = path or statusline_file()
    try:
        raw = target.read_text(encoding="utf-8")
        age = max(0.0, time.time() - target.stat().st_mtime)
    except OSError:
        return None
    try:
        document = json.loads(raw)
    except ValueError:
        LOGGER.debug("Nieczytelny snapshot Claude Code w %s", target)
        return None
    return parse(document, age_seconds=age)
