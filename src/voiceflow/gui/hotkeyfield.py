"""The "press the shortcut you want" field.

A text box for a hotkey asks the user to know a syntax, spell it correctly, and
then wait for a daemon restart to find out they got it wrong. This records the
chord instead, and answers the only question that matters — is it free — before
anything is written to disk.
"""

from __future__ import annotations

from PySide6.QtCore import QTimer, Signal
from PySide6.QtWidgets import QHBoxLayout, QLineEdit, QPushButton, QVBoxLayout, QWidget

from voiceflow.gui import service, theme
from voiceflow.gui.widgets import BackgroundCall, label

#: A hook swallows the whole keyboard, so an abandoned capture would leave the
#: machine unusable. It always ends by itself.
_CAPTURE_TIMEOUT_MS = 8000

_PROBE_TEXT = {
    "free": ("Wolny — żadna inna aplikacja go nie zajmuje.", theme.POSITIVE),
    "taken": ("Zajęty przez inną aplikację — wybierz inny.", theme.ACCENT),
    "current": ("To skrót, na którym demon nasłuchuje teraz.", theme.MUTED),
}


class HotkeyField(QWidget):
    """Record a chord, then say whether Windows will give it to us."""

    changed = Signal()

    def __init__(self) -> None:
        super().__init__()
        self._value = ""
        self._capture = None

        self._display = QLineEdit()
        self._display.setReadOnly(True)
        self._display.setPlaceholderText("ctrl+shift+space")
        self._button = QPushButton("Nagraj skrót")
        self._button.clicked.connect(self._toggle_capture)

        self._status = label("", name="faint", wrap=True)

        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(6)
        top = QHBoxLayout()
        top.setContentsMargins(0, 0, 0, 0)
        top.setSpacing(12)
        top.addWidget(self._display, 1)
        top.addWidget(self._button, 0)
        layout.addLayout(top)
        layout.addWidget(self._status)

        self._timeout = QTimer(self)
        self._timeout.setSingleShot(True)
        self._timeout.setInterval(_CAPTURE_TIMEOUT_MS)
        self._timeout.timeout.connect(lambda: self._finish(None))

    # -- value ---------------------------------------------------------------

    def value(self) -> str:
        return self._value

    def set_value(self, binding: str) -> None:
        """Load a binding from the config without reporting it as an edit."""
        self._value = binding
        self._display.setText(binding)
        self._set_status("", theme.FAINT)

    # -- capture -------------------------------------------------------------

    def _toggle_capture(self) -> None:
        if self._capture is not None:
            self._finish(None)
        else:
            self._start_capture()

    def _start_capture(self) -> None:
        from voiceflow.winplat.keycapture import KeyCapture

        # The result arrives from inside the hook procedure. Unhooking there
        # would tear down a hook that is still on the stack, so bounce through
        # the event loop first: by the time _finish runs, the hook has returned.
        capture = KeyCapture(
            lambda binding, cancelled: QTimer.singleShot(
                0, lambda: self._finish(binding, recorded=not cancelled)
            )
        )
        try:
            capture.start()
        except OSError as exc:
            self._set_status(str(exc), theme.ACCENT)
            return
        self._capture = capture
        self._display.setText("Naciśnij kombinację…   Esc anuluje")
        self._button.setText("Anuluj")
        self._set_status(
            "Klawiatura jest przechwytywana — nic nie trafi do innych okien.", theme.WARNING
        )
        self._timeout.start()

    def _finish(self, binding: str | None, *, recorded: bool = False) -> None:
        self._timeout.stop()
        if self._capture is not None:
            self._capture.stop()
            self._capture = None
        self._button.setText("Nagraj skrót")

        if binding is None:
            self._display.setText(self._value)
            self._set_status(
                "Ten klawisz nie może być skrótem — spróbuj innego." if recorded else "",
                theme.MUTED,
            )
            return

        self._display.setText(binding)
        if binding != self._value:
            self._value = binding
            self.changed.emit()
        self._probe(binding)

    # -- availability --------------------------------------------------------

    def _probe(self, binding: str) -> None:
        self._set_status("Sprawdzam, czy skrót jest wolny…", theme.MUTED)
        BackgroundCall(
            lambda: service.probe_binding(binding),
            lambda result: self._show_probe(binding, result),
            lambda message: self._set_status(message, theme.ACCENT),
        )

    def _show_probe(self, binding: str, result: object) -> None:
        # A stale answer for a chord the user has already replaced would be
        # worse than none: it would label the new binding with the old verdict.
        if binding != self._value:
            return
        text, colour = _PROBE_TEXT.get(
            str(result), ("Nie udało się sprawdzić dostępności skrótu.", theme.WARNING)
        )
        self._set_status(text, colour)

    def _set_status(self, text: str, colour: str) -> None:
        self._status.setText(text)
        self._status.setStyleSheet(f"color: {colour};" if text else "")
