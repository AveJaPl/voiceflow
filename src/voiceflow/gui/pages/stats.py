"""Statistics computed entirely from the local history file."""

from __future__ import annotations

from typing import Any

from PySide6.QtWidgets import QHBoxLayout, QVBoxLayout, QWidget

from voiceflow import statlib
from voiceflow.gui import service
from voiceflow.gui.charts import ActivityGrid, BarChart
from voiceflow.gui.widgets import (
    BackgroundCall,
    Card,
    StatTile,
    label,
    page_header,
    page_scroll,
)

DAILY_DAYS = 30
ACTIVITY_WEEKS = 26


class StatsPage(QWidget):
    """Four totals, a daily bar series, and a 26-week activity grid."""

    def __init__(self, window) -> None:
        super().__init__()
        self._window = window

        body = QWidget()
        layout = QVBoxLayout(body)
        layout.setContentsMargins(36, 32, 36, 36)
        layout.setSpacing(22)
        layout.addWidget(
            page_header("Statystyki", "Twój rytm dyktowania, liczony wyłącznie z lokalnej historii.")
        )

        tiles = QWidget()
        tile_layout = QHBoxLayout(tiles)
        tile_layout.setContentsMargins(0, 0, 0, 0)
        tile_layout.setSpacing(16)
        self._tiles = {
            "words": StatTile("Łącznie słów"),
            "dictations": StatTile("Dyktowań"),
            "audio": StatTile("Czas mówienia"),
            "average": StatTile("Średnio słów"),
        }
        for tile in self._tiles.values():
            tile_layout.addWidget(tile, 1)
        layout.addWidget(tiles)

        daily_card = Card()
        daily_card.body.addWidget(label(f"Słowa dziennie · {DAILY_DAYS} dni", name="card-title"))
        self._bars = BarChart()
        daily_card.body.addWidget(self._bars)
        layout.addWidget(daily_card)

        activity_card = Card()
        activity_card.body.addWidget(
            label(f"Aktywność · {ACTIVITY_WEEKS} tygodni", name="card-title")
        )
        self._grid = ActivityGrid()
        activity_card.body.addWidget(self._grid)
        self._empty = label("", name="faint", wrap=True)
        activity_card.body.addWidget(self._empty)
        layout.addWidget(activity_card)
        layout.addStretch(1)

        outer = QVBoxLayout(self)
        outer.setContentsMargins(0, 0, 0, 0)
        outer.addWidget(page_scroll(body))

    def refresh(self) -> None:
        BackgroundCall(_aggregate, self._apply)

    def _apply(self, data: object) -> None:
        if not isinstance(data, dict):
            return
        self._tiles["words"].set_value(statlib.compact_number(data["words"]))
        self._tiles["dictations"].set_value(statlib.compact_number(data["dictations"]))
        self._tiles["audio"].set_value(statlib.format_duration(data["audio_seconds"]))
        self._tiles["average"].set_value(f"{data['average_words']:.0f}".replace(".", ","))
        self._bars.set_series(data["daily"])
        self._grid.set_data(data["activity"], data["levels"])
        self._empty.setText(
            "" if data["dictations"] else "Brak danych — podyktuj coś, a wykresy się wypełnią."
        )


def _aggregate() -> dict[str, Any]:
    records = service.history_records()
    aggregate = statlib.totals(records)
    activity = statlib.daily_series(records, ACTIVITY_WEEKS * 7)
    return {
        "words": int(aggregate["words"]),
        "dictations": int(aggregate["dictations"]),
        "audio_seconds": float(aggregate["audio_seconds"]),
        "average_words": float(aggregate["average_words"]),
        "daily": statlib.daily_series(records, DAILY_DAYS),
        "activity": activity,
        "levels": statlib.activity_levels(activity),
    }
