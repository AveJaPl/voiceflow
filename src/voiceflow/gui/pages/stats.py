"""Statistics page with compact local-history visualizations."""

from __future__ import annotations

from datetime import date, timedelta
from typing import Any

from PySide6.QtWidgets import QVBoxLayout, QWidget

from voiceflow import statlib
from voiceflow.gui import theme
from voiceflow.gui.charts import ActivityGrid, BarChart
from voiceflow.gui.widgets import (
    Card,
    empty_state,
    hbox,
    label,
    page_body,
    page_header,
    page_scroll,
    plain,
    vbox,
)

#: Half a year, the way the GTK grid is drawn: 26 columns of seven days.
ACTIVITY_WEEKS = 26


class StatsPage(QWidget):
    """Aggregate and visualize the local JSONL history."""

    def __init__(self) -> None:
        super().__init__()
        clamp, layout = page_body()
        layout.addWidget(
            page_header(
                "Statystyki", "Twój rytm dyktowania, liczony wyłącznie z lokalnej historii."
            )
        )

        self._holder = vbox(0)
        layout.addLayout(self._holder)
        layout.addStretch(1)

        self._content = plain(vbox(theme.SPACE_32))
        self._content.layout().addWidget(self._build_summary())
        self._content.layout().addWidget(self._build_bar_chart())
        self._content.layout().addWidget(self._build_activity_chart())

        outer = QVBoxLayout(self)
        outer.setContentsMargins(0, 0, 0, 0)
        outer.addWidget(page_scroll(clamp))
        self.update_history([])

    # -- construction --------------------------------------------------------

    def _build_summary(self) -> QWidget:
        holder = plain(hbox(theme.SPACE_16))
        self._summary: dict[str, Any] = {}
        for key, title in (
            ("words", "Łącznie słów"),
            ("dictations", "Dyktowań"),
            ("duration", "Czas mówienia"),
            ("average", "Średnio słów"),
        ):
            card = Card(padding=theme.SPACE_16, spacing=theme.SPACE_8)
            card.setMinimumHeight(88)
            card.body.setContentsMargins(
                theme.SPACE_20, theme.SPACE_16, theme.SPACE_20, theme.SPACE_16
            )
            card.body.addWidget(label(title.upper(), "stat-label"))
            value = label("0", "stat-value")
            card.body.addWidget(value)
            self._summary[key] = value
            holder.layout().addWidget(card, 1)
        return holder

    def _build_bar_chart(self) -> QWidget:
        card = Card(spacing=theme.SPACE_16)
        card.setMinimumHeight(240)
        card.body.addWidget(label("Słowa dziennie", "card-title"))
        self.bar_chart = BarChart()
        card.body.addWidget(self.bar_chart)
        return card

    def _build_activity_chart(self) -> QWidget:
        card = Card(spacing=theme.SPACE_16)
        card.setMinimumHeight(240)
        card.body.addWidget(label(f"Aktywność · {ACTIVITY_WEEKS} tygodni", "card-title"))
        self.activity_chart = ActivityGrid()
        card.body.addWidget(self.activity_chart)
        return card

    # -- data ----------------------------------------------------------------

    def update_history(self, records: list[dict[str, Any]]) -> None:
        """Recalculate statistics, update the empty state, and redraw charts."""
        summary = statlib.totals(records)
        self._summary["words"].setText(statlib.compact_number(int(summary["words"])))
        self._summary["dictations"].setText(
            statlib.compact_number(int(summary["dictations"]))
        )
        self._summary["duration"].setText(
            statlib.format_duration(float(summary["audio_seconds"]))
        )
        self._summary["average"].setText(f"{float(summary['average_words']):.0f}")

        today = date.today()
        self.bar_chart.set_series(statlib.daily_series(records, BarChart.DAYS, today=today))

        week_start = today - timedelta(days=today.weekday())
        activity_start = week_start - timedelta(weeks=ACTIVITY_WEEKS - 1)
        totals = statlib.daily_word_totals(records)
        series = [
            (
                activity_start + timedelta(days=index),
                totals.get(activity_start + timedelta(days=index), 0),
            )
            for index in range(ACTIVITY_WEEKS * 7)
        ]
        self.activity_chart.set_data(series, statlib.activity_levels(series))

        # The charts stay built and simply leave the tree while there is nothing
        # to draw — rebuilding them on every history refresh would be waste.
        clear_layout_keeping(self._holder, self._content)
        if records:
            self._holder.addWidget(self._content)
            self._content.setVisible(True)
        else:
            self._content.setVisible(False)
            self._holder.addWidget(
                empty_state(
                    "view-grid-symbolic",
                    "Brak statystyk. Pierwsze dyktowanie uruchomi podsumowania i wykresy.",
                )
            )


def clear_layout_keeping(layout, keep: QWidget) -> None:
    """Empty a layout, detaching — never destroying — one widget it may hold."""
    while layout.count():
        item = layout.takeAt(0)
        widget = item.widget()
        if widget is None:
            continue
        widget.setParent(None)
        if widget is not keep:
            widget.deleteLater()
