"""Persistent record of past dictations.

Two jobs, one file:

1. **Retrieval.** On GNOME Wayland the daemon cannot know which window received
   the paste — focus is invisible to applications. When a dictation lands in the
   wrong window (or nowhere), the text must still be recoverable: ``voiceflow
   last --copy`` and the settings app both read it from here.
2. **Statistics.** Words per day, streaks, activity calendars — all derivable
   from these records without ever re-reading audio.

Format: one JSON object per line (JSONL) in the XDG data directory. Text storage
is optional (``history.store_text``) for people who dictate sensitive content;
counts alone still power the statistics.
"""

from __future__ import annotations

import json
import logging
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path

from voiceflow.config import HistoryConfig
from voiceflow.paths import history_file

LOGGER = logging.getLogger(__name__)


@dataclass(frozen=True, slots=True)
class Record:
    """One completed dictation."""

    timestamp: str
    words: int
    chars: int
    audio_seconds: float
    transcription_seconds: float
    injected: bool
    text: str | None = None

    @staticmethod
    def now(
        text: str,
        *,
        audio_seconds: float,
        transcription_seconds: float,
        injected: bool,
        store_text: bool,
    ) -> "Record":
        """Build a record for a dictation that just finished."""
        return Record(
            timestamp=datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds"),
            words=len(text.split()),
            chars=len(text),
            audio_seconds=round(audio_seconds, 2),
            transcription_seconds=round(transcription_seconds, 3),
            injected=injected,
            text=text if store_text else None,
        )


class History:
    """Append-only dictation log with size-capped pruning."""

    def __init__(self, config: HistoryConfig, path: Path | None = None) -> None:
        self.config = config
        self.path = path or history_file()
        if config.enabled:
            self._prune_if_oversized()

    def append(self, record: Record) -> None:
        """Persist one record. Failures are logged, never raised: losing a
        history line must not break the dictation that produced it."""
        if not self.config.enabled:
            return
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            entry = {key: value for key, value in asdict(record).items() if value is not None}
            with self.path.open("a", encoding="utf-8") as handle:
                handle.write(json.dumps(entry, ensure_ascii=False) + "\n")
        except OSError as exc:
            LOGGER.warning("Nie można zapisać historii dyktowania: %s", exc)

    def _prune_if_oversized(self) -> None:
        """Trim the file to the newest ``max_entries`` lines, at startup only."""
        try:
            if not self.path.exists():
                return
            lines = self.path.read_text(encoding="utf-8").splitlines()
            if len(lines) <= self.config.max_entries:
                return
            kept = lines[-self.config.max_entries :]
            tmp = self.path.with_suffix(".jsonl.tmp")
            tmp.write_text("\n".join(kept) + "\n", encoding="utf-8")
            tmp.replace(self.path)
            LOGGER.info("Przycięto historię do %d wpisów", len(kept))
        except OSError as exc:
            LOGGER.warning("Nie można przyciąć historii: %s", exc)


def read_records(path: Path | None = None, *, limit: int | None = None) -> list[Record]:
    """Read records oldest-first, skipping unparseable lines.

    Used by the CLI and the settings app; both read the file directly rather
    than going through the daemon, so history survives daemon downtime.
    """
    target = path or history_file()
    if not target.exists():
        return []
    records: list[Record] = []
    try:
        lines = target.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        LOGGER.warning("Nie można odczytać historii: %s", exc)
        return []
    if limit is not None:
        lines = lines[-limit:]
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            data = json.loads(line)
            records.append(
                Record(
                    timestamp=str(data["timestamp"]),
                    words=int(data["words"]),
                    chars=int(data["chars"]),
                    audio_seconds=float(data.get("audio_seconds", 0.0)),
                    transcription_seconds=float(data.get("transcription_seconds", 0.0)),
                    injected=bool(data.get("injected", True)),
                    text=data.get("text"),
                )
            )
        except (json.JSONDecodeError, KeyError, TypeError, ValueError):
            LOGGER.debug("Pomijam nieczytelny wpis historii: %r", line[:80])
    return records
