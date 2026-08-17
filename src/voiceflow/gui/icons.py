"""The symbolic icons the GTK application takes from the desktop icon theme.

Windows has no icon theme to borrow from, and shipping a PNG set would mean
bitmaps that blur on a 150% display and colours that ignore the palette. Each
icon here is therefore drawn as strokes on a 24×24 grid and rendered at the
requested size in the requested colour — monochrome line art, the same idea as
GNOME's ``-symbolic`` set, so the two windows carry the same marks.

The names are the GTK icon names on purpose: a page asking for
``audio-input-microphone-symbolic`` in both applications is a page that is
demonstrably the same page.
"""

from __future__ import annotations

from PySide6.QtCore import QPointF, QRectF, Qt
from PySide6.QtGui import QColor, QIcon, QPainter, QPainterPath, QPen, QPixmap

from voiceflow.gui import theme

#: Every path below is authored against this box and scaled on paint.
_GRID = 24.0


def _microphone(path: QPainterPath) -> None:
    path.addRoundedRect(QRectF(9, 2.5, 6, 11), 3, 3)
    # The cradle: the lower half of a circle around the capsule, drawn from
    # nine o'clock round the bottom to three o'clock.
    cradle = QRectF(5.5, 6.5, 13, 13)
    path.arcMoveTo(cradle, 180)
    path.arcTo(cradle, 180, -180)
    path.moveTo(12, 19)
    path.lineTo(12, 22)
    path.moveTo(8.5, 22)
    path.lineTo(15.5, 22)


def _clock(path: QPainterPath) -> None:
    path.addEllipse(QRectF(2.5, 2.5, 19, 19))
    path.moveTo(12, 6.5)
    path.lineTo(12, 12)
    path.lineTo(16, 14.5)


def _grid(path: QPainterPath) -> None:
    for x in (3.0, 13.5):
        for y in (3.0, 13.5):
            path.addRoundedRect(QRectF(x, y, 7.5, 7.5), 1.5, 1.5)


def _users(path: QPainterPath) -> None:
    path.addEllipse(QRectF(6, 3, 7, 7))
    path.moveTo(2.5, 21)
    path.arcTo(QRectF(2.5, 11.5, 14, 14), 180, -180)
    path.addEllipse(QRectF(14.5, 4.5, 5.5, 5.5))
    path.moveTo(16, 12.5)
    path.arcTo(QRectF(13, 12.5, 9, 9), 90, -90)


def _book(path: QPainterPath) -> None:
    path.addRoundedRect(QRectF(4, 3, 16, 18), 2, 2)
    path.moveTo(8, 3)
    path.lineTo(8, 21)
    path.moveTo(11.5, 8)
    path.lineTo(16.5, 8)


def _gear(path: QPainterPath) -> None:
    from math import cos, pi, sin

    path.addEllipse(QRectF(8.8, 8.8, 6.4, 6.4))
    path.addEllipse(QRectF(4.5, 4.5, 15, 15))
    for index in range(8):
        angle = index * pi / 4
        path.moveTo(QPointF(12 + 7.5 * cos(angle), 12 + 7.5 * sin(angle)))
        path.lineTo(QPointF(12 + 10.5 * cos(angle), 12 + 10.5 * sin(angle)))


def _copy(path: QPainterPath) -> None:
    path.addRoundedRect(QRectF(8.5, 8.5, 12, 12), 2, 2)
    path.moveTo(15.5, 3.5)
    path.lineTo(5.5, 3.5)
    path.lineTo(3.5, 5.5)
    path.lineTo(3.5, 15.5)


def _refresh(path: QPainterPath) -> None:
    path.arcMoveTo(QRectF(3.5, 3.5, 17, 17), 60)
    path.arcTo(QRectF(3.5, 3.5, 17, 17), 60, 280)
    path.moveTo(20, 3)
    path.lineTo(20.2, 8.4)
    path.lineTo(15, 7.4)


def _trash(path: QPainterPath) -> None:
    path.moveTo(3.5, 6)
    path.lineTo(20.5, 6)
    path.moveTo(9, 6)
    path.lineTo(9, 3.5)
    path.lineTo(15, 3.5)
    path.lineTo(15, 6)
    path.moveTo(5.5, 6)
    path.lineTo(6.6, 20.5)
    path.lineTo(17.4, 20.5)
    path.lineTo(18.5, 6)
    path.moveTo(10, 10)
    path.lineTo(10, 17)
    path.moveTo(14, 10)
    path.lineTo(14, 17)


def _close(path: QPainterPath) -> None:
    path.moveTo(6, 6)
    path.lineTo(18, 18)
    path.moveTo(18, 6)
    path.lineTo(6, 18)


def _chevron(path: QPainterPath) -> None:
    path.moveTo(9, 4.5)
    path.lineTo(16.5, 12)
    path.lineTo(9, 19.5)


def _wireless(path: QPainterPath) -> None:
    # Three arcs opening upward from one centre, plus the transmitter dot.
    for radius in (9.0, 6.0, 3.0):
        arc = QRectF(12 - radius, 18 - radius, radius * 2, radius * 2)
        path.arcMoveTo(arc, 40)
        path.arcTo(arc, 40, 100)
    path.addEllipse(QRectF(10.75, 16.75, 2.5, 2.5))


def _error(path: QPainterPath) -> None:
    path.addEllipse(QRectF(2.5, 2.5, 19, 19))
    path.moveTo(12, 6.5)
    path.lineTo(12, 13.5)
    path.moveTo(12, 17)
    path.lineTo(12, 17.6)


_PAINTERS = {
    "audio-input-microphone-symbolic": _microphone,
    "document-open-recent-symbolic": _clock,
    "view-grid-symbolic": _grid,
    "system-users-symbolic": _users,
    "accessories-dictionary-symbolic": _book,
    "emblem-system-symbolic": _gear,
    "edit-copy-symbolic": _copy,
    "view-refresh-symbolic": _refresh,
    "user-trash-symbolic": _trash,
    "window-close-symbolic": _close,
    "go-next-symbolic": _chevron,
    "network-wireless-symbolic": _wireless,
    "dialog-error-symbolic": _error,
}


def pixmap(
    name: str,
    size: int = 16,
    colour: str = theme.TEXT_PRIMARY,
    *,
    ratio: float = 1.0,
) -> QPixmap:
    """Draw one icon at ``size`` logical pixels in ``colour``."""
    physical = max(1, int(round(size * ratio)))
    canvas = QPixmap(physical, physical)
    canvas.setDevicePixelRatio(ratio)
    canvas.fill(Qt.GlobalColor.transparent)
    painter = QPainter(canvas)
    painter.setRenderHint(QPainter.RenderHint.Antialiasing)
    painter.scale(physical / _GRID, physical / _GRID)
    pen = QPen(QColor(colour))
    # Authored for a 24 px box; 1.7 is the weight that reads like the GNOME set
    # at 16 px without turning into a smudge at 32.
    pen.setWidthF(1.7)
    pen.setCapStyle(Qt.PenCapStyle.RoundCap)
    pen.setJoinStyle(Qt.PenJoinStyle.RoundJoin)
    painter.setPen(pen)
    painter.setBrush(Qt.BrushStyle.NoBrush)
    path = QPainterPath()
    builder = _PAINTERS.get(name)
    if builder is not None:
        builder(path)
    painter.drawPath(path)
    painter.end()
    return canvas


def icon(name: str, size: int = 16, colour: str = theme.TEXT_PRIMARY) -> QIcon:
    """An icon carrying both the 1× and 2× rendering, so it stays crisp."""
    result = QIcon()
    for ratio in (1.0, 2.0):
        result.addPixmap(pixmap(name, size, colour, ratio=ratio))
    return result
