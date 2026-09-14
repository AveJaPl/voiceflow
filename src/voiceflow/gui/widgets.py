"""The building blocks the pages are assembled from.

One entry here for each construct the GTK application uses — the card, the
clamped page, the empty state, the stat card, the switch row, the volume
slider — so a page can be ported by translating its structure rather than
reinventing its parts. Where libadwaita supplies a widget Qt has no equivalent
for (``Adw.SwitchRow``, the recording pulse, the navigation indicator), it is
painted here once instead of being approximated differently on every page.
"""

from __future__ import annotations

from collections.abc import Callable

from PySide6.QtCore import (
    QEasingCurve,
    QObject,
    QPropertyAnimation,
    QRectF,
    QSize,
    QThread,
    Qt,
    Property,
    Signal,
)
from PySide6.QtGui import (
    QColor,
    QFontMetrics,
    QPainter,
    QPainterPath,
    QPen,
    QTextLayout,
    QTransform,
)
from PySide6.QtWidgets import (
    QAbstractButton,
    QComboBox,
    QFrame,
    QHBoxLayout,
    QLabel,
    QLayout,
    QProgressBar,
    QPushButton,
    QScrollArea,
    QSizePolicy,
    QSlider,
    QVBoxLayout,
    QWidget,
)

from voiceflow.gui import icons, theme


# -- primitives --------------------------------------------------------------


class StyledWidget(QWidget):
    """A QWidget subclass that honours background and border from the stylesheet.

    Qt applies those two properties to plain ``QWidget`` instances but not to
    subclasses, which silently lose them — this is the documented opt-in, and
    it is why the settings rows have their hairline separators.
    """

    def paintEvent(self, event) -> None:  # noqa: N802 - Qt naming
        from PySide6.QtWidgets import QStyle, QStyleOption

        option = QStyleOption()
        option.initFrom(self)
        painter = QPainter(self)
        self.style().drawPrimitive(QStyle.PrimitiveElement.PE_Widget, option, painter, self)
        painter.end()


def plain(layout: QLayout | None = None) -> QWidget:
    """A layout-only container that lets the card behind it show through."""
    widget = QWidget()
    widget.setObjectName("plain")
    if layout is not None:
        widget.setLayout(layout)
    return widget


def label(text: str, name: str = "", *, wrap: bool = False, selectable: bool = False) -> QLabel:
    """A left-aligned label carrying a semantic object name, as in GTK."""
    widget = QLabel(text)
    if name:
        widget.setObjectName(name)
    widget.setWordWrap(wrap)
    widget.setAlignment(Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignVCenter)
    if wrap:
        widget.setSizePolicy(QSizePolicy.Policy.Preferred, QSizePolicy.Policy.Minimum)
    if selectable:
        widget.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
    return widget


def section_label(text: str) -> QLabel:
    """The all-caps group heading that opens every section."""
    return label(text.upper(), "section-label")


def icon_label(name: str, size: int = 16, colour: str = theme.TEXT_PRIMARY) -> QLabel:
    widget = QLabel()
    widget.setObjectName("plain")
    widget.setPixmap(icons.pixmap(name, size, colour, ratio=2.0))
    widget.setFixedSize(size, size)
    return widget


def vbox(spacing: int = theme.SPACE_12, margins: int = 0) -> QVBoxLayout:
    layout = QVBoxLayout()
    layout.setContentsMargins(margins, margins, margins, margins)
    layout.setSpacing(spacing)
    return layout


def hbox(spacing: int = theme.SPACE_12, margins: int = 0) -> QHBoxLayout:
    layout = QHBoxLayout()
    layout.setContentsMargins(margins, margins, margins, margins)
    layout.setSpacing(spacing)
    return layout


def column(*widgets: QWidget, spacing: int = theme.SPACE_8) -> QWidget:
    layout = vbox(spacing)
    for widget in widgets:
        layout.addWidget(widget)
    return plain(layout)


def row(*widgets: QWidget, spacing: int = theme.SPACE_12, stretch: int = -1) -> QWidget:
    """A horizontal strip; ``stretch`` names the index that takes the slack."""
    layout = hbox(spacing)
    for index, widget in enumerate(widgets):
        layout.addWidget(widget, 1 if index == stretch else 0)
    if stretch < 0:
        layout.addStretch(1)
    return plain(layout)


# -- cards and pages ---------------------------------------------------------


class Card(QFrame):
    """A matte rounded panel; the page's unit of content."""

    def __init__(
        self,
        *,
        padding: int = theme.SPACE_20,
        spacing: int = theme.SPACE_12,
        horizontal: bool = False,
    ) -> None:
        super().__init__()
        self.setObjectName("card")
        self.body: QLayout = QHBoxLayout(self) if horizontal else QVBoxLayout(self)
        self.body.setContentsMargins(padding, padding, padding, padding)
        self.body.setSpacing(spacing)


def page_scroll(content: QWidget) -> QScrollArea:
    """Wrap a page body so long pages scroll without resizing the window."""
    area = QScrollArea()
    area.setObjectName("page-scroll")
    area.setWidgetResizable(True)
    area.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
    area.setWidget(content)
    return area


def page_body(spacing: int = theme.SPACE_32) -> tuple[QWidget, QVBoxLayout]:
    """The clamped, consistently padded page column Adw.Clamp gives GTK.

    Content stops widening at 1120 px and stays centred, so a maximised window
    does not stretch a settings row across a metre of desk.
    """
    clamp = QWidget()
    clamp.setObjectName("page-clamp")
    outer = QHBoxLayout(clamp)
    outer.setContentsMargins(theme.SPACE_32, theme.SPACE_32, theme.SPACE_32, theme.SPACE_24)
    outer.setSpacing(0)

    inner = QWidget()
    inner.setObjectName("plain")
    inner.setMaximumWidth(theme.PAGE_MAX_WIDTH)
    layout = QVBoxLayout(inner)
    layout.setContentsMargins(0, 0, 0, 0)
    layout.setSpacing(spacing)

    outer.addStretch(1)
    outer.addWidget(inner, 10)
    outer.addStretch(1)
    return clamp, layout


def page_header(title: str, description: str) -> QWidget:
    """The in-content page intro.

    The title itself lives in the window header bar — set by the navigation
    handler — so only the one-sentence description renders here. The parameter
    stays for call-site readability, exactly as on the GTK side.
    """
    del title  # shown in the header bar, not in the content
    return column(label(description, "page-subtitle", wrap=True), spacing=theme.SPACE_4)


def empty_state(icon_name: str, message: str) -> QWidget:
    """A compact, centred empty state without oversized whitespace."""
    card = Card(padding=theme.SPACE_20, spacing=theme.SPACE_12)
    card.setMinimumHeight(96)
    glyph = icon_label(icon_name, 32, theme.TEXT_TERTIARY_SOLID)
    glyph.setAlignment(Qt.AlignmentFlag.AlignCenter)
    holder = plain(hbox(0))
    holder.layout().addStretch(1)
    holder.layout().addWidget(glyph)
    holder.layout().addStretch(1)
    card.body.addWidget(holder)
    text = label(message, "empty-message", wrap=True)
    text.setAlignment(Qt.AlignmentFlag.AlignCenter)
    card.body.addWidget(text)
    return card


def clear_layout(layout: QLayout) -> None:
    """Remove and destroy every child, the way GTK's remove-first-child loop does."""
    while layout.count():
        item = layout.takeAt(0)
        widget = item.widget()
        if widget is not None:
            widget.setParent(None)
            widget.deleteLater()
        elif item.layout() is not None:
            clear_layout(item.layout())


# -- indicators --------------------------------------------------------------


class StatusDot(QLabel):
    """The small ● that reports whether something is alive."""

    def __init__(self, colour: str = theme.TEXT_TERTIARY_SOLID) -> None:
        super().__init__("●")
        self.setObjectName("plain")
        self._colour = ""
        self.set_colour(colour)

    def set_colour(self, colour: str) -> None:
        if colour == self._colour:
            return
        self._colour = colour
        self.setStyleSheet(f"color: {colour}; font-size: 12px; background: transparent;")


class RecordingDot(StatusDot):
    """The pulsing red dot GTK animates with ``@keyframes recording-pulse``."""

    def __init__(self) -> None:
        super().__init__(theme.RECORDING)
        # Set before the animation exists: constructing one reads the property,
        # and a Property getter that runs before __init__ finished would raise.
        self._pulse = 1.0
        self._animation = QPropertyAnimation(self, b"pulse", self)
        self._animation.setDuration(1200)
        self._animation.setStartValue(1.0)
        self._animation.setKeyValueAt(0.5, 0.35)
        self._animation.setEndValue(1.0)
        self._animation.setEasingCurve(QEasingCurve.Type.InOutSine)
        self._animation.setLoopCount(-1)

    def _get_pulse(self) -> float:
        return getattr(self, "_pulse", 1.0)

    def _set_pulse(self, value: float) -> None:
        self._pulse = value
        shade = QColor(theme.RECORDING)
        shade.setAlphaF(max(0.0, min(1.0, value)))
        self.setStyleSheet(
            f"color: rgba({shade.red()},{shade.green()},{shade.blue()},{shade.alphaF():.3f});"
            " font-size: 13px; background: transparent;"
        )

    pulse = Property(float, _get_pulse, _set_pulse)

    def setVisible(self, visible: bool) -> None:  # noqa: N802 - Qt naming
        # An animation left running behind a hidden dot is a timer firing sixty
        # times a second for nothing.
        super().setVisible(visible)
        if visible:
            self._animation.start()
        else:
            self._animation.stop()


class BrandWave(QWidget):
    """The three-bar mark beside the wordmark in the sidebar."""

    def __init__(self) -> None:
        super().__init__()
        self.setObjectName("plain")
        self.setFixedSize(16, 16)

    def paintEvent(self, event) -> None:  # noqa: N802 - Qt naming
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        painter.setPen(Qt.PenStyle.NoPen)
        painter.setBrush(QColor(theme.TEXT_PRIMARY))
        for index, height in enumerate((8.0, 16.0, 8.0)):
            x = index * 6.0 + 1.0
            painter.drawRoundedRect(QRectF(x, (16 - height) / 2, 2.0, height), 1.0, 1.0)
        painter.end()


class ShareBar(QProgressBar):
    """The 4 px share meter under a name on the room board."""

    def __init__(self) -> None:
        super().__init__()
        self.setObjectName("plain")
        self.setTextVisible(False)
        self.setRange(0, 100)
        self.setFixedHeight(4)
        self.setStyleSheet(
            "QProgressBar { background-color: rgba(255,255,255,0.08);"
            " border: none; border-radius: 2px; }"
            "QProgressBar::chunk { background-color: rgba(255,255,255,0.45);"
            " border-radius: 2px; }"
        )


# -- navigation --------------------------------------------------------------


class NavButton(QPushButton):
    """A sidebar row: icon, label, and the selection bar down its left edge."""

    def __init__(self, icon_name: str, text: str) -> None:
        super().__init__(text)
        self.setObjectName("nav-button")
        self.setCheckable(True)
        self.setCursor(Qt.CursorShape.PointingHandCursor)
        self._icon_name = icon_name
        self._refresh_icon()
        self.setIconSize(QSize(16, 16))
        self.toggled.connect(lambda _checked: self._refresh_icon())

    def _refresh_icon(self) -> None:
        colour = theme.TEXT_PRIMARY if self.isChecked() else theme.TEXT_SECONDARY_SOLID
        self.setIcon(icons.icon(self._icon_name, 16, colour))

    def enterEvent(self, event) -> None:  # noqa: N802 - Qt naming
        self.setIcon(icons.icon(self._icon_name, 16, theme.TEXT_PRIMARY))
        super().enterEvent(event)

    def leaveEvent(self, event) -> None:  # noqa: N802 - Qt naming
        self._refresh_icon()
        super().leaveEvent(event)

    def paintEvent(self, event) -> None:  # noqa: N802 - Qt naming
        super().paintEvent(event)
        if not self.isChecked():
            return
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        painter.setPen(Qt.PenStyle.NoPen)
        painter.setBrush(QColor(theme.TEXT_PRIMARY))
        painter.drawRoundedRect(QRectF(0, (self.height() - 24) / 2, 3, 24), 2, 2)
        painter.end()


# -- controls ----------------------------------------------------------------


class Switch(QAbstractButton):
    """libadwaita's switch, painted.

    Qt's checkbox is a tick in a box; every settings row in the GTK application
    ends in a sliding switch. Drawing one is a dozen lines and keeps the two
    windows visually identical, which a checkbox would not.
    """

    def __init__(self, checked: bool = False) -> None:
        super().__init__()
        self.setCheckable(True)
        self.setChecked(checked)
        self.setCursor(Qt.CursorShape.PointingHandCursor)
        self.setFixedSize(44, 24)
        self._offset = 1.0 if checked else 0.0
        self._animation = QPropertyAnimation(self, b"offset", self)
        self._animation.setDuration(theme.MOTION_MS)
        self._animation.setEasingCurve(QEasingCurve.Type.InOutQuad)
        self.toggled.connect(self._animate)

    def _animate(self, checked: bool) -> None:
        self._animation.stop()
        self._animation.setStartValue(self._offset)
        self._animation.setEndValue(1.0 if checked else 0.0)
        self._animation.start()

    def _get_offset(self) -> float:
        return self._offset

    def _set_offset(self, value: float) -> None:
        self._offset = value
        self.update()

    offset = Property(float, _get_offset, _set_offset)

    def setChecked(self, checked: bool) -> None:  # noqa: N802 - Qt naming
        # Programmatic loading must land on the final position immediately;
        # animating a form as it populates looks like the user did it.
        super().setChecked(checked)
        if not self._has_animation():
            return
        self._animation.stop()
        self._set_offset(1.0 if checked else 0.0)

    def _has_animation(self) -> bool:
        return getattr(self, "_animation", None) is not None

    def paintEvent(self, event) -> None:  # noqa: N802 - Qt naming
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        painter.setPen(Qt.PenStyle.NoPen)
        track = QColor(theme.TEXT_SECONDARY_SOLID) if self.isChecked() else QColor(theme.RAISED_BG)
        if not self.isEnabled():
            track.setAlphaF(0.4)
        painter.setBrush(track)
        painter.drawRoundedRect(QRectF(0, 0, 44, 24), 12, 12)
        knob = QColor(theme.TEXT_PRIMARY)
        if not self.isEnabled():
            knob.setAlphaF(0.45)
        painter.setBrush(knob)
        painter.drawEllipse(QRectF(2 + self._offset * 20, 2, 20, 20))
        painter.end()


class Combo(QComboBox):
    """A drop-down that draws its own chevron.

    Qt's ``::down-arrow`` wants an image file, and a styled drop-down without
    one renders as a blank square — a control that does not look clickable.
    """

    def paintEvent(self, event) -> None:  # noqa: N802 - Qt naming
        super().paintEvent(event)
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        pen = QPen(QColor(theme.TEXT_SECONDARY_SOLID))
        pen.setWidthF(1.4)
        pen.setCapStyle(Qt.PenCapStyle.RoundCap)
        pen.setJoinStyle(Qt.PenJoinStyle.RoundJoin)
        painter.setPen(pen)
        centre_y = self.height() / 2
        right = self.width() - 16
        path = QPainterPath()
        path.moveTo(right - 4.5, centre_y - 2)
        path.lineTo(right, centre_y + 2.5)
        path.lineTo(right + 4.5, centre_y - 2)
        painter.drawPath(path)
        painter.end()


def volume_slider() -> QSlider:
    """The 176 px ducking slider, 0–100 with no printed value."""
    slider = QSlider(Qt.Orientation.Horizontal)
    slider.setObjectName("plain")
    slider.setRange(0, 100)
    slider.setFixedWidth(176)
    return slider


def volume_label() -> QLabel:
    widget = label("0%", "volume-value")
    widget.setAlignment(Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter)
    widget.setMinimumWidth(112)
    return widget


def volume_text(percent: float) -> str:
    """Label the slider as what it is: a share of the app's own volume."""
    rounded = int(round(percent))
    if rounded == 100:
        return "100% · nie ściszaj"
    return f"{rounded}% obecnej"


# -- settings rows -----------------------------------------------------------


class SettingsRow(StyledWidget):
    """One row of a settings card: title, optional subtitle, suffix widgets."""

    def __init__(self, title: str = "", subtitle: str = "") -> None:
        super().__init__()
        self.setObjectName("settings-row")
        self.setMinimumHeight(64)
        layout = QHBoxLayout(self)
        layout.setContentsMargins(theme.SPACE_16, theme.SPACE_8, theme.SPACE_16, theme.SPACE_8)
        layout.setSpacing(theme.SPACE_12)

        self._title = label(title, "row-title", wrap=True)
        self._subtitle = label(subtitle, "row-subtitle", wrap=True)
        self._subtitle.setVisible(bool(subtitle))
        text = vbox(2)
        text.addWidget(self._title)
        text.addWidget(self._subtitle)
        layout.addLayout(text, 1)
        self._layout = layout

    def set_title(self, text: str) -> None:
        self._title.setText(text)

    def set_subtitle(self, text: str) -> None:
        self._subtitle.setText(text)
        self._subtitle.setVisible(bool(text))

    def add_suffix(self, widget: QWidget) -> None:
        widget.setSizePolicy(QSizePolicy.Policy.Fixed, QSizePolicy.Policy.Preferred)
        self._layout.addWidget(widget, 0, Qt.AlignmentFlag.AlignVCenter)

    def set_inactive(self, inactive: bool) -> None:
        """Dim a row that names something not currently running."""
        self.setProperty("inactive", "true" if inactive else "false")
        repolish(self)


class SwitchRow(SettingsRow):
    """A settings row whose control is a switch — libadwaita's ``SwitchRow``."""

    toggled = Signal(bool)

    def __init__(self, title: str, subtitle: str = "", checked: bool = False) -> None:
        super().__init__(title, subtitle)
        self.switch = Switch(checked)
        self.switch.toggled.connect(self.toggled.emit)
        self.add_suffix(self.switch)

    def is_checked(self) -> bool:
        return self.switch.isChecked()

    def set_checked(self, checked: bool) -> None:
        self.switch.setChecked(checked)


class SettingsCard(QFrame):
    """A card that stacks settings rows and separates them with hairlines."""

    def __init__(self) -> None:
        super().__init__()
        self.setObjectName("settings-card")
        self._layout = QVBoxLayout(self)
        self._layout.setContentsMargins(0, theme.SPACE_4, 0, theme.SPACE_4)
        self._layout.setSpacing(0)
        self._rows: list[QWidget] = []

    def append(self, widget: QWidget) -> None:
        self._layout.addWidget(widget)
        self._rows.append(widget)
        self._mark_last()

    def remove(self, widget: QWidget) -> None:
        if widget not in self._rows:
            return
        self._rows.remove(widget)
        self._layout.removeWidget(widget)
        widget.setParent(None)
        widget.deleteLater()
        self._mark_last()

    def rows(self) -> list[QWidget]:
        return list(self._rows)

    def _mark_last(self) -> None:
        # The final row must not draw a separator against the card's own edge.
        for index, widget in enumerate(self._rows):
            widget.setProperty("last", "true" if index == len(self._rows) - 1 else "false")
            repolish(widget)


def repolish(widget: QWidget) -> None:
    """Qt only restyles on an explicit repolish after a property change."""
    style = widget.style()
    style.unpolish(widget)
    style.polish(widget)
    widget.update()


# -- stat cards --------------------------------------------------------------


class StatCard(Card):
    """Caption, headline number with optional suffix, and a trend line."""

    def __init__(self, title: str, suffix: str = "") -> None:
        super().__init__(padding=theme.SPACE_16, spacing=theme.SPACE_8)
        self.setMinimumHeight(88)
        self.body.setContentsMargins(theme.SPACE_20, theme.SPACE_16, theme.SPACE_20, theme.SPACE_16)
        self.body.addWidget(label(title.upper(), "stat-label"))

        self._value = label("0", "stat-value")
        value_row = hbox(theme.SPACE_8)
        value_row.addWidget(self._value)
        if suffix:
            suffix_label = label(suffix, "stat-suffix")
            value_row.addWidget(suffix_label, 0, Qt.AlignmentFlag.AlignBottom)
        value_row.addStretch(1)
        self.body.addLayout(value_row)

        self._trend = label("", "stat-trend")
        self.body.addWidget(self._trend)

    def set_value(self, value: str) -> None:
        self._value.setText(value)

    def set_trend(self, text: str) -> None:
        self._trend.setText(text)


class Sparkline(QWidget):
    """The seven-bar week strip inside the overview's fourth stat card."""

    def __init__(self) -> None:
        super().__init__()
        self.setObjectName("plain")
        self.setFixedHeight(48)
        self.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed)
        self._series: list[tuple[object, int]] = []

    def set_series(self, series: list[tuple[object, int]]) -> None:
        self._series = list(series)
        self.update()

    def paintEvent(self, event) -> None:  # noqa: N802 - Qt naming
        if not self._series:
            return
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        painter.setPen(Qt.PenStyle.NoPen)
        width, height = self.width(), self.height()
        maximum = max((value for _day, value in self._series), default=0)
        slot = width / 7
        bar_width = max(4.0, min(18.0, slot * 0.48))
        baseline = height - 2.0
        for index, (_day, value) in enumerate(self._series):
            bar_height = (
                max(3.0, (value / maximum) * (height - 4.0))
                if value > 0 and maximum > 0
                else 3.0
            )
            x = index * slot + (slot - bar_width) / 2
            colour = QColor(255, 255, 255)
            colour.setAlphaF(theme.CHART_ALPHA_ACTIVE if value else theme.CHART_ALPHA_IDLE)
            painter.setBrush(colour)
            painter.drawRect(QRectF(x, baseline - bar_height, bar_width, bar_height))
        painter.end()


class ClampedLabel(QLabel):
    """Wrap to at most N lines and end the last one with an ellipsis.

    Qt elides on one line only; GTK does it per paragraph through Pango, which
    is what the history preview and the latest-dictation card rely on. Laying
    the text out by hand is the honest way to get the same result — clipping
    instead would cut a word in half and pretend the entry is that short.
    """

    def __init__(self, text: str = "", name: str = "", lines: int = 2) -> None:
        super().__init__()
        if name:
            self.setObjectName(name)
        self._lines = max(1, lines)
        self._full = text
        self.setWordWrap(True)
        self.setAlignment(Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignTop)
        self.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Fixed)
        self.setFixedHeight(self._lines * QFontMetrics(self.font()).lineSpacing())
        self.setText(text)

    def set_full_text(self, text: str) -> None:
        self._full = text
        self._relayout()

    def resizeEvent(self, event) -> None:  # noqa: N802 - Qt naming
        super().resizeEvent(event)
        self._relayout()

    def _relayout(self) -> None:
        metrics = QFontMetrics(self.font())
        width = max(1, self.width())
        layout = QTextLayout(self._full, self.font())
        layout.beginLayout()
        shown: list[str] = []
        overflowed = False
        while True:
            line = layout.createLine()
            if not line.isValid():
                break
            line.setLineWidth(width)
            start, length = line.textStart(), line.textLength()
            if len(shown) == self._lines:
                overflowed = True
                break
            shown.append(self._full[start : start + length])
        layout.endLayout()
        if overflowed and shown:
            shown[-1] = metrics.elidedText(
                shown[-1] + "…", Qt.TextElideMode.ElideRight, width
            )
        super().setText("".join(shown).strip())


class Chevron(QLabel):
    """The disclosure arrow on a history card; rotates when expanded."""

    def __init__(self) -> None:
        super().__init__()
        self.setObjectName("plain")
        self.setFixedSize(16, 16)
        self._expanded = False
        self._paint()

    def set_expanded(self, expanded: bool) -> None:
        if expanded == self._expanded:
            return
        self._expanded = expanded
        self._paint()

    def _paint(self) -> None:
        colour = theme.TEXT_PRIMARY if self._expanded else theme.TEXT_SECONDARY_SOLID
        source = icons.pixmap("go-next-symbolic", 16, colour, ratio=2.0)
        if self._expanded:
            # GTK rotates it with -gtk-icon-transform; the pixmap turns instead.
            source = source.transformed(
                QTransform().rotate(90), Qt.TransformationMode.SmoothTransformation
            )
        self.setPixmap(source)


class Separator(QFrame):
    """A one-pixel hairline in the border colour."""

    def __init__(self) -> None:
        super().__init__()
        self.setObjectName("plain")
        self.setFixedHeight(1)
        self.setStyleSheet(f"background-color: {theme.BORDER_SOLID};")


# -- threading ---------------------------------------------------------------


class Worker(QObject):
    """Run one blocking call off the UI thread and deliver the result back.

    Every service call — talking to the daemon, enumerating audio sessions,
    reading history — can block for seconds. Doing that on the UI thread is
    what makes an application feel broken, so nothing here runs inline.
    """

    done = Signal(object)
    failed = Signal(str)

    def __init__(self, work: Callable[[], object]) -> None:
        super().__init__()
        self._work = work

    def run(self) -> None:
        try:
            result = self._work()
        except Exception as exc:  # noqa: BLE001 - surfaced to the user as text
            self.failed.emit(str(exc))
            return
        self.done.emit(result)


class BackgroundCall(QObject):
    """Own a worker plus its thread, and hand the result back on the UI thread.

    Being a QObject created on the UI thread is what makes this correct, not
    decoration: the worker's signals cross into this object's thread, so the
    callbacks below always run where it is legal to touch widgets. Connecting
    a plain lambda straight to the worker would instead run it on the worker
    thread — the classic way to corrupt a Qt UI.

    The instance also keeps itself referenced until the thread ends; a QThread
    whose last reference is dropped is destroyed mid-flight.
    """

    finished = Signal(object)
    errored = Signal(str)

    _live: set["BackgroundCall"] = set()

    def __init__(
        self,
        work: Callable[[], object],
        on_done: Callable[[object], None] | None = None,
        on_failed: Callable[[str], None] | None = None,
    ) -> None:
        super().__init__()
        if on_done is not None:
            self.finished.connect(on_done)
        if on_failed is not None:
            self.errored.connect(on_failed)

        self._thread = QThread()
        self._worker = Worker(work)
        self._worker.moveToThread(self._thread)
        self._thread.started.connect(self._worker.run)
        # Queued into this object's (UI) thread, because self lives there.
        self._worker.done.connect(self._deliver)
        self._worker.failed.connect(self._fail)
        # quit() is thread-safe; cleanup waits for finished, which arrives here.
        self._worker.done.connect(self._thread.quit)
        self._worker.failed.connect(self._thread.quit)
        self._thread.finished.connect(self._cleanup)

        BackgroundCall._live.add(self)
        self._thread.start()

    def _deliver(self, result: object) -> None:
        self.finished.emit(result)

    def _fail(self, message: str) -> None:
        self.errored.emit(message)

    def _cleanup(self) -> None:
        self._worker.deleteLater()
        BackgroundCall._live.discard(self)

    @classmethod
    def drain(cls, timeout_ms: int = 2000) -> None:
        """Let outstanding work end before the process exits."""
        for call in list(cls._live):
            call._thread.quit()
            call._thread.wait(timeout_ms)
        cls._live.clear()
