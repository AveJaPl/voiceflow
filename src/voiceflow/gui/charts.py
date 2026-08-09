"""Hand-drawn charts: a daily bar series and a GitHub-style activity grid.

Qt ships no charting in the base wheel, and pulling one in for two figures
would be disproportionate. Both are a few dozen lines of QPainter, which also
keeps them exactly on the product's palette.
"""

from __future__ import annotations

from datetime import date

from PySide6.QtCore import QRectF, Qt
from PySide6.QtGui import QColor, QPainter, QPainterPath
from PySide6.QtWidgets import QSizePolicy, QToolTip, QWidget

from voiceflow.gui import theme

_MONTHS = ("sty", "lut", "mar", "kwi", "maj", "cze", "lip", "sie", "wrz", "paź", "lis", "gru")


class BarChart(QWidget):
    """Words per day, oldest on the left."""

    def __init__(self) -> None:
        super().__init__()
        self._series: list[tuple[date, int]] = []
        self.setMinimumHeight(190)
        self.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed)
        self.setMouseTracking(True)

    def set_series(self, series: list[tuple[date, int]]) -> None:
        self._series = list(series)
        self.update()

    def _geometry(self) -> tuple[float, float, float]:
        count = max(len(self._series), 1)
        width = self.width()
        slot = width / count
        bar = max(2.0, min(slot * 0.62, 22.0))
        return slot, bar, max((value for _day, value in self._series), default=0)

    def paintEvent(self, event) -> None:  # noqa: N802 - Qt naming
        if not self._series:
            return
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        slot, bar_width, peak = self._geometry()
        floor = self.height() - 20.0
        usable = floor - 8.0

        painter.setPen(QColor(theme.BORDER))
        painter.drawLine(0, int(floor) + 1, self.width(), int(floor) + 1)

        for index, (day, value) in enumerate(self._series):
            centre = slot * (index + 0.5)
            height = (value / peak) * usable if peak > 0 else 0.0
            rect = QRectF(centre - bar_width / 2, floor - height, bar_width, max(height, 1.5))
            path = QPainterPath()
            radius = min(5.0, bar_width / 2)
            path.addRoundedRect(rect, radius, radius)
            painter.fillPath(path, QColor(theme.ACCENT if value else theme.CARD))

        # Month ticks only where the month changes: a label per day is noise.
        painter.setPen(QColor(theme.FAINT))
        font = painter.font()
        font.setPointSizeF(8.5)
        painter.setFont(font)
        previous_month = None
        for index, (day, _value) in enumerate(self._series):
            if day.month != previous_month:
                previous_month = day.month
                painter.drawText(
                    QRectF(slot * index - 14, floor + 4, 40, 16),
                    Qt.AlignmentFlag.AlignLeft,
                    _MONTHS[day.month - 1],
                )
        painter.end()

    def mouseMoveEvent(self, event) -> None:  # noqa: N802 - Qt naming
        if not self._series:
            return
        slot, _bar, _peak = self._geometry()
        index = int(event.position().x() // slot)
        if 0 <= index < len(self._series):
            day, value = self._series[index]
            QToolTip.showText(
                event.globalPosition().toPoint(),
                f"{day.strftime('%d.%m.%Y')} — {value} słów",
                self,
            )


class ActivityGrid(QWidget):
    """Weeks as columns, weekdays as rows, coloured by quantile."""

    CELL = 13.0
    GAP = 3.0

    def __init__(self) -> None:
        super().__init__()
        self._series: list[tuple[date, int]] = []
        self._levels: dict[date, int] = {}
        self.setMinimumHeight(int(7 * (self.CELL + self.GAP)) + 22)
        self.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed)
        self.setMouseTracking(True)

    def set_data(self, series: list[tuple[date, int]], levels: dict[date, int]) -> None:
        self._series = list(series)
        self._levels = dict(levels)
        self.update()

    def _cell_rect(self, index: int, day: date) -> QRectF:
        # Monday-first rows; the first column may start mid-week.
        offset = self._series[0][0].weekday() if self._series else 0
        position = index + offset
        column, weekday = divmod(position, 7)
        return QRectF(
            column * (self.CELL + self.GAP),
            weekday * (self.CELL + self.GAP) + 16,
            self.CELL,
            self.CELL,
        )

    def paintEvent(self, event) -> None:  # noqa: N802 - Qt naming
        if not self._series:
            return
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        painter.setPen(QColor(theme.FAINT))
        font = painter.font()
        font.setPointSizeF(8.5)
        painter.setFont(font)

        previous_month = None
        for index, (day, _value) in enumerate(self._series):
            rect = self._cell_rect(index, day)
            if day.month != previous_month and day.day <= 7:
                previous_month = day.month
                painter.drawText(
                    QRectF(rect.left(), 0, 40, 14),
                    Qt.AlignmentFlag.AlignLeft,
                    _MONTHS[day.month - 1],
                )
            path = QPainterPath()
            path.addRoundedRect(rect, 3.0, 3.0)
            painter.fillPath(path, QColor(theme.HEAT[self._levels.get(day, 0)]))
        painter.end()

    def mouseMoveEvent(self, event) -> None:  # noqa: N802 - Qt naming
        point = event.position()
        for index, (day, value) in enumerate(self._series):
            if self._cell_rect(index, day).contains(point):
                QToolTip.showText(
                    event.globalPosition().toPoint(),
                    f"{day.strftime('%d.%m.%Y')} — {value} słów",
                    self,
                )
                return
