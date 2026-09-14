"""Hand-drawn charts: a daily bar series and a 26-week activity grid.

Both are ports of the Cairo drawing in ``app/voiceflow_app/pages/stats.py`` —
same geometry, same white-at-five-alphas palette, same labels. Qt ships no
charting in the base wheel, and pulling a library in for two figures would be
disproportionate when each is a few dozen lines of QPainter.
"""

from __future__ import annotations

from datetime import date

from PySide6.QtCore import QRectF, Qt
from PySide6.QtGui import QColor, QPainter, QPainterPath
from PySide6.QtWidgets import QSizePolicy, QToolTip, QWidget

from voiceflow.gui import theme

DAY_NAMES = ("pn", "wt", "śr", "cz", "pt", "sob", "nd")
MONTH_NAMES = (
    "",
    "sty",
    "lut",
    "mar",
    "kwi",
    "maj",
    "cze",
    "lip",
    "sie",
    "wrz",
    "paź",
    "lis",
    "gru",
)

#: The five white alphas the GTK activity grid uses, idle first.
ACTIVITY_ALPHAS = (0.07, 0.35, 0.55, 0.55, 1.0)


def _white(alpha: float) -> QColor:
    colour = QColor(255, 255, 255)
    colour.setAlphaF(max(0.0, min(1.0, alpha)))
    return colour


class BarChart(QWidget):
    """Words per day over a fortnight, oldest on the left."""

    DAYS = 14

    def __init__(self) -> None:
        super().__init__()
        self.setObjectName("plain")
        self._series: list[tuple[date, int]] = []
        self.setMinimumHeight(200)
        self.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed)

    def set_series(self, series: list[tuple[date, int]]) -> None:
        self._series = list(series)
        self.update()

    def paintEvent(self, event) -> None:  # noqa: N802 - Qt naming
        if not self._series:
            return
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        width, height = self.width(), self.height()
        left, right, top, bottom = 8.0, 8.0, 24.0, 32.0
        usable_width = max(1.0, width - left - right)
        baseline = height - bottom
        chart_height = max(1.0, baseline - top)
        slot = usable_width / self.DAYS
        bar_width = max(8.0, min(24.0, slot * 0.48))
        maximum = max((value for _day, value in self._series), default=0)
        peak_index = max(
            range(len(self._series)), key=lambda index: self._series[index][1], default=0
        )

        font = painter.font()
        font.setPixelSize(11)
        painter.setFont(font)
        today = date.today()

        for index, (day, value) in enumerate(self._series):
            x = left + index * slot + (slot - bar_width) / 2
            if value > 0 and maximum > 0:
                bar_height = max(4.0, (value / maximum) * (chart_height - 16.0))
                alpha = theme.CHART_ALPHA_ACTIVE
            else:
                bar_height = 4.0
                alpha = theme.CHART_ALPHA_IDLE
            y = baseline - bar_height
            painter.setPen(Qt.PenStyle.NoPen)
            painter.fillPath(
                _rounded_top_bar(x, y, bar_width, bar_height, 3.0), _white(alpha)
            )

            painter.setPen(_white(1.0 if day == today else 0.35))
            painter.drawText(
                QRectF(x - slot / 2, height - 20, bar_width + slot, 16),
                Qt.AlignmentFlag.AlignHCenter | Qt.AlignmentFlag.AlignVCenter,
                DAY_NAMES[day.weekday()],
            )

            if index == peak_index and value > 0:
                painter.setPen(_white(theme.CHART_ALPHA_ACTIVE))
                painter.drawText(
                    QRectF(x - slot / 2, max(2.0, y - 20), bar_width + slot, 16),
                    Qt.AlignmentFlag.AlignHCenter | Qt.AlignmentFlag.AlignBottom,
                    f"{value:,}".replace(",", " "),
                )
        painter.end()


class ActivityGrid(QWidget):
    """Twenty-six weeks as columns, weekdays as rows, coloured by quantile."""

    WEEKS = 26
    CELL = 12.0
    GAP = 4.0

    def __init__(self) -> None:
        super().__init__()
        self.setObjectName("plain")
        self._series: list[tuple[date, int]] = []
        self._levels: dict[date, int] = {}
        self._cells: list[tuple[float, float, date, int]] = []
        self.setMinimumHeight(160)
        self.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed)
        self.setMouseTracking(True)

    def set_data(self, series: list[tuple[date, int]], levels: dict[date, int]) -> None:
        self._series = list(series)
        self._levels = dict(levels)
        self.update()

    def _left(self) -> float:
        step = self.CELL + self.GAP
        grid_width = self.WEEKS * self.CELL + (self.WEEKS - 1) * self.GAP
        return max(48.0, (self.width() - grid_width) / 2)

    def paintEvent(self, event) -> None:  # noqa: N802 - Qt naming
        if not self._series:
            return
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        step = self.CELL + self.GAP
        left, top = self._left(), 32.0
        self._cells = []

        font = painter.font()
        font.setPixelSize(11)
        painter.setFont(font)
        painter.setPen(_white(0.35))
        for row, day_label in ((0, "pn"), (2, "śr"), (4, "pt")):
            painter.drawText(
                QRectF(left - 30, top + row * step, 24, self.CELL),
                Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter,
                day_label,
            )

        previous_month = 0
        for week in range(self.WEEKS):
            week_day = self._series[week * 7][0]
            if week_day.month != previous_month:
                painter.drawText(
                    QRectF(left + week * step, 4, 40, 14),
                    Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignVCenter,
                    MONTH_NAMES[week_day.month],
                )
                previous_month = week_day.month

        today = date.today()
        painter.setPen(Qt.PenStyle.NoPen)
        for index, (day, value) in enumerate(self._series):
            week, weekday = divmod(index, 7)
            x = left + week * step
            y = top + weekday * step
            level = self._levels.get(day, 0)
            alpha = ACTIVITY_ALPHAS[level] if day <= today else theme.CHART_ALPHA_IDLE
            path = QPainterPath()
            path.addRoundedRect(QRectF(x, y, self.CELL, self.CELL), 3.0, 3.0)
            painter.fillPath(path, _white(alpha))
            self._cells.append((x, y, day, value))
        painter.end()

    def mouseMoveEvent(self, event) -> None:  # noqa: N802 - Qt naming
        point = event.position()
        today = date.today()
        for x, y, day, value in self._cells:
            if x <= point.x() <= x + self.CELL and y <= point.y() <= y + self.CELL:
                if day > today:
                    return
                QToolTip.showText(
                    event.globalPosition().toPoint(),
                    f"{day.strftime('%d.%m.%Y')} · {value} słów",
                    self,
                )
                return
        QToolTip.hideText()


def _rounded_top_bar(x: float, y: float, width: float, height: float, radius: float) -> QPainterPath:
    """A bar with square lower and rounded upper corners."""
    radius = min(radius, width / 2, height)
    path = QPainterPath()
    path.moveTo(x, y + height)
    path.lineTo(x, y + radius)
    path.arcTo(QRectF(x, y, 2 * radius, 2 * radius), 180, -90)
    path.lineTo(x + width - radius, y)
    path.arcTo(QRectF(x + width - 2 * radius, y, 2 * radius, 2 * radius), 90, -90)
    path.lineTo(x + width, y + height)
    path.closeSubpath()
    return path
