"""How much of the Claude Code limits this machine has burned through.

Read from `~/.claude/statusline-last.json`, the snapshot Claude Code writes for
its own status line. Only the two percentages and their reset times are taken —
never the session name, the working directory, the cost in dollars or anything
that could say what the person was working on.

Sharing this with a room is on by default (`room.share_claude_usage`) —
a room is a shared table, and these are bare numbers with nothing about what
anyone worked on. The switch stays for whoever prefers to keep them private.

Like the now-playing tile, the value travels over the room WebSocket and is
never stored — there is no table for it.
"""

from __future__ import annotations

import datetime
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


def projects_dir() -> Path:
    return Path.home() / ".claude" / "projects"


class TokenCounter:
    """Sum today's Claude Code token usage from the session transcripts.

    The transcripts hold full conversations, so this class must never let any
    of that content out: it extracts four integers per line and nothing else.

    Two measured facts shape the implementation. One API response is written
    as SEVERAL transcript lines carrying the same ``requestId`` and identical
    ``usage`` — counting lines would triple the numbers, so responses are
    deduplicated by id. And a single day of transcripts can run to hundreds of
    megabytes, so files are read incrementally: only bytes appended since the
    previous look, with per-file offsets. Everything resets at local midnight.
    """

    def __init__(self, root: Path | None = None, refresh_seconds: float = 60.0) -> None:
        self._root = root or projects_dir()
        self._refresh = refresh_seconds
        self._day: str | None = None
        self._offsets: dict[Path, int] = {}
        self._seen: set[str] = set()
        self._tokens_in = 0
        self._tokens_out = 0
        self._cached_at: float | None = None

    def tokens_today(self, now: float | None = None) -> tuple[int, int]:
        """Return (input incl. cache, output) tokens since local midnight."""
        now = time.time() if now is None else now
        local = datetime.datetime.fromtimestamp(now)
        day = local.strftime("%Y-%m-%d")
        if day != self._day:
            self._day = day
            self._offsets.clear()
            self._seen.clear()
            self._tokens_in = self._tokens_out = 0
            self._cached_at = None
        if self._cached_at is not None and now - self._cached_at < self._refresh:
            return (self._tokens_in, self._tokens_out)
        midnight = local.replace(hour=0, minute=0, second=0, microsecond=0)
        # Timestamps in transcripts are UTC ISO strings; those sort like time,
        # so "since midnight" is a plain string comparison against this cutoff.
        cutoff_iso = midnight.astimezone(datetime.UTC).strftime("%Y-%m-%dT%H:%M:%S")
        cutoff_epoch = midnight.timestamp()
        try:
            files = list(self._root.rglob("*.jsonl"))
        except OSError:
            files = []
        for path in files:
            try:
                stat = path.stat()
            except OSError:
                continue
            offset = self._offsets.get(path, 0)
            if stat.st_mtime < cutoff_epoch and offset == 0:
                # Untouched since midnight: nothing from today inside.
                continue
            if stat.st_size < offset:
                # Truncated/rewritten; reread — the seen-ids set keeps already
                # counted responses from counting twice.
                offset = 0
            if stat.st_size == offset:
                continue
            self._offsets[path] = self._read_from(path, offset, cutoff_iso)
        self._cached_at = now
        return (self._tokens_in, self._tokens_out)

    def _read_from(self, path: Path, offset: int, cutoff_iso: str) -> int:
        """Count complete new lines; return the offset up to which we read."""
        try:
            with path.open("rb") as handle:
                handle.seek(offset)
                chunk = handle.read()
        except OSError:
            return offset
        if not chunk:
            return offset
        # A writer may be mid-line; only what ends with a newline is complete.
        complete = chunk if chunk.endswith(b"\n") else chunk[: chunk.rfind(b"\n") + 1]
        for line in complete.splitlines():
            if b'"usage"' not in line:
                continue
            self._count_line(line, cutoff_iso)
        return offset + len(complete)

    def _count_line(self, line: bytes, cutoff_iso: str) -> None:
        try:
            entry = json.loads(line)
        except ValueError:
            return
        if not isinstance(entry, dict):
            return
        timestamp = entry.get("timestamp")
        if not isinstance(timestamp, str) or timestamp < cutoff_iso:
            return
        message = entry.get("message")
        usage = message.get("usage") if isinstance(message, dict) else None
        if not isinstance(usage, dict):
            return
        request_id = entry.get("requestId") or usage.get("request_id")
        if isinstance(request_id, str):
            if request_id in self._seen:
                return
            self._seen.add(request_id)

        def _count(key: str) -> int:
            value = usage.get(key)
            return int(value) if isinstance(value, (int, float)) and value > 0 else 0

        self._tokens_in += (
            _count("input_tokens")
            + _count("cache_creation_input_tokens")
            + _count("cache_read_input_tokens")
        )
        self._tokens_out += _count("output_tokens")


_COUNTER: TokenCounter | None = None


def current_payload(
    path: Path | None = None,
    counter: TokenCounter | None = None,
    now: float | None = None,
) -> dict[str, int] | None:
    """The full room payload: limit percentages plus today's token counts.

    Still numbers only — a stale status line with fresh transcripts (or the
    other way round) yields a partial payload rather than none, because half
    the picture is better than a missing tile.
    """
    global _COUNTER
    if counter is None:
        if _COUNTER is None:
            _COUNTER = TokenCounter()
        counter = _COUNTER
    usage = current_usage(path)
    tokens_in, tokens_out = counter.tokens_today(now=now)
    if usage is None and tokens_in == 0 and tokens_out == 0:
        return None
    payload = usage.as_payload() if usage else {"fiveHour": 0, "sevenDay": 0, "resetsAt": 0}
    payload["tokensIn"] = tokens_in
    payload["tokensOut"] = tokens_out
    return payload


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
