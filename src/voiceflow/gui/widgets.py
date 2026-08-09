"""Small building blocks shared by the pages."""

from __future__ import annotations

from collections.abc import Callable

from PySide6.QtCore import QObject, QThread, Qt, Signal
from PySide6.QtWidgets import (
    QFrame,
    QHBoxLayout,
    QLabel,
    QScrollArea,
    QSizePolicy,
    QVBoxLayout,
    QWidget,
)

from voiceflow.gui import theme


class Card(QFrame):
    """A matte rounded panel; the page's unit of content."""

    def __init__(self, parent: QWidget | None = None, *, padding: int = 20) -> None:
        super().__init__(parent)
        self.setObjectName("card")
        self.body = QVBoxLayout(self)
        self.body.setContentsMargins(padding, padding, padding, padding)
        self.body.setSpacing(14)


def label(text: str, *, name: str = "", wrap: bool = False) -> QLabel:
    widget = QLabel(text)
    if name:
        widget.setObjectName(name)
    widget.setWordWrap(wrap)
    if wrap:
        widget.setSizePolicy(QSizePolicy.Policy.Preferred, QSizePolicy.Policy.Minimum)
    widget.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
    return widget


def section_label(text: str) -> QLabel:
    return label(text.upper(), name="section-label")


class StatTile(Card):
    """A single headline number with its caption."""

    def __init__(self, caption: str, value: str = "—") -> None:
        super().__init__(padding=18)
        self.body.setSpacing(6)
        self._value = label(value, name="stat-value")
        self.body.addWidget(self._value)
        self.body.addWidget(label(caption.upper(), name="stat-label"))

    def set_value(self, value: str) -> None:
        self._value.setText(value)


class StatusDot(QWidget):
    """The same red dot the overlay shows, as a state indicator."""

    def __init__(self, colour: str = theme.FAINT) -> None:
        super().__init__()
        self._colour = colour
        self.setFixedSize(12, 12)

    def set_colour(self, colour: str) -> None:
        if colour != self._colour:
            self._colour = colour
            self.update()

    def paintEvent(self, event) -> None:  # noqa: N802 - Qt naming
        from PySide6.QtGui import QColor, QPainter

        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        painter.setPen(Qt.PenStyle.NoPen)
        painter.setBrush(QColor(self._colour))
        painter.drawEllipse(1, 1, 10, 10)
        painter.end()


def page_scroll(content: QWidget) -> QScrollArea:
    """Wrap a page body so long pages scroll without the window resizing."""
    area = QScrollArea()
    area.setWidgetResizable(True)
    area.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
    area.setWidget(content)
    return area


def page_header(title: str, subtitle: str) -> QWidget:
    header = QWidget()
    layout = QVBoxLayout(header)
    layout.setContentsMargins(0, 0, 0, 0)
    layout.setSpacing(6)
    layout.addWidget(label(title, name="page-title"))
    layout.addWidget(label(subtitle, name="page-subtitle", wrap=True))
    return header


def row(*widgets: QWidget, spacing: int = 12, stretch_last: bool = False) -> QWidget:
    container = QWidget()
    layout = QHBoxLayout(container)
    layout.setContentsMargins(0, 0, 0, 0)
    layout.setSpacing(spacing)
    for index, widget in enumerate(widgets):
        layout.addWidget(widget, 1 if stretch_last and index == len(widgets) - 1 else 0)
    if not stretch_last:
        layout.addStretch(1)
    return container


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
