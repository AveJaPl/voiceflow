"""On-screen dictation indicator for Windows, built on tkinter (stdlib).

Same protocol as the Linux overlay controller (``start``/``update``/``stop``),
but in-process: tkinter runs on a dedicated thread with a queue instead of a
child process on the system Python. The window is borderless, always-on-top,
bottom-centered, and — the part that matters — must never take the focus away
from the window that is going to receive the paste.

That last part takes two mechanisms, because one is not enough. ``WS_EX_NOACTIVATE``
keeps the card from being activated once it exists, but tkinter takes the
foreground the instant it *realizes* its window — before any style of ours can
be applied to a handle that does not exist yet. So the window in front is
remembered before tkinter is started and handed back afterwards, and only if
the card is the one holding it. Without this the dictation was pasted into an
overlay nobody can type in, which looks exactly like injection being broken.
"""

from __future__ import annotations

import logging
import queue
import threading

from voiceflow.config import OverlayConfig

LOGGER = logging.getLogger(__name__)

_WS_EX_NOACTIVATE = 0x08000000
_WS_EX_TOOLWINDOW = 0x00000080
_GWL_EXSTYLE = -20

_BG = "#141416"
_FG = "#f5f5f7"
_MUTED = "#8b8b96"
#: A notice is a finished outcome, so it borrows the inert "transcribing" dot
#: rather than introducing a colour that would read as a new live state.
_DOT = {
    "listening": "#ff453a",
    "transcribing": "#3a3a3f",
    "notice": "#3a3a3f",
    "error": "#ff9f0a",
}

#: How long a self-closing notice stays up, in milliseconds. Matches the Linux
#: overlay so the two platforms feel the same.
NOTICE_TIMEOUT_MS = 2400


def _user32():
    """user32, imported where it exists — and replaceable in tests."""
    import ctypes

    return ctypes.windll.user32  # type: ignore[attr-defined]


def foreground_window() -> int:
    """The window in front right now — the one the dictation is meant for."""
    try:
        return int(_user32().GetForegroundWindow() or 0)
    except Exception:  # noqa: BLE001 - a missing foreground is not an error
        return 0


def window_handle(root) -> int:
    """The toplevel Windows frame behind a Tk window, or 0 if there is none.

    For an ``overrideredirect`` Tk window the widget handle is a child of the
    frame Windows actually activates, and that frame is what every call here
    cares about.
    """
    try:
        user32 = _user32()
        widget = root.winfo_id()
        return int(user32.GetParent(widget) or widget)
    except Exception:  # noqa: BLE001 - the window may be gone already
        return 0


def hand_back_foreground(previous: int, ours: int) -> None:
    """Give the foreground back to ``previous``, but only if ``ours`` took it.

    The guard is the whole point: the card undoes its own theft and nothing
    else. Pulling a window forward that the user chose in the meantime would be
    the same rudeness in the other direction.
    """
    if not previous or not ours or previous == ours:
        return
    try:
        user32 = _user32()
        if user32.GetForegroundWindow() != ours:
            return
        user32.SetForegroundWindow(previous)
    except Exception:  # noqa: BLE001 - focus is best effort, never fatal
        LOGGER.debug("Nie udało się oddać focusu oknu %s", previous)


class WinOverlay:
    """Thread-hosted tkinter card mirroring the Linux overlay behaviour."""

    def __init__(self, config: OverlayConfig) -> None:
        self.config = config
        self._queue: queue.Queue[tuple[str, str | None] | None] = queue.Queue()
        self._thread: threading.Thread | None = None

    @property
    def is_running(self) -> bool:
        return self._thread is not None and self._thread.is_alive()

    def start(self, state: str = "listening", text: str | None = None) -> None:
        if not self.config.enabled:
            return
        if not self.is_running:
            self._queue = queue.Queue()
            # Which window is this dictation for? Read here, on the caller's
            # thread, because the answer is gone a moment after tkinter starts.
            self._thread = threading.Thread(
                target=self._run,
                args=(foreground_window(),),
                name="voiceflow-overlay",
                daemon=True,
            )
            self._thread.start()
        self.update(state, text)

    def update(self, state: str, text: str | None = None) -> None:
        if self.is_running:
            self._queue.put((state, text))

    def notice(self, text: str, *, timeout_ms: int | None = None) -> None:
        """Show a short message, then take the card down on a timer.

        Interface parity with the Linux overlay, which the daemon calls when a
        recording turned out to contain no speech. The self-close lives here
        rather than in the tkinter thread: that thread only knows how to render
        whatever state it was last handed.
        """
        if not self.config.enabled:
            return
        if not self.is_running:
            self.start("notice", text)
        else:
            self.update("notice", text)
        delay = (timeout_ms if timeout_ms is not None else NOTICE_TIMEOUT_MS) / 1000
        threading.Timer(delay, self.stop).start()

    def stop(self) -> None:
        if self.is_running:
            self._queue.put(None)
            assert self._thread is not None
            self._thread.join(timeout=2)
        self._thread = None

    def _run(self, previous: int = 0) -> None:  # pragma: no cover - needs a display
        try:
            import tkinter
        except ImportError:
            LOGGER.warning("Brak tkintera — okno podglądu wyłączone")
            return
        root = tkinter.Tk()
        root.withdraw()
        root.overrideredirect(True)
        root.attributes("-topmost", True)
        root.configure(bg=_BG)

        def no_activate() -> None:
            """Mark the window unfocusable, so it cannot swallow the paste.

            The style belongs on the toplevel Windows frame, which for an
            overrideredirect Tk window is the parent of the widget handle.
            """
            try:
                import ctypes

                user32 = ctypes.windll.user32  # type: ignore[attr-defined]
                widget = root.winfo_id()
                hwnd = user32.GetParent(widget) or widget
                style = user32.GetWindowLongW(hwnd, _GWL_EXSTYLE)
                user32.SetWindowLongW(
                    hwnd, _GWL_EXSTYLE, style | _WS_EX_NOACTIVATE | _WS_EX_TOOLWINDOW
                )
            except Exception:
                LOGGER.exception("Nie udało się ustawić WS_EX_NOACTIVATE")

        def hand_back() -> None:
            """Return the foreground to whoever had it before this card."""
            hand_back_foreground(previous, window_handle(root))

        # Realizing the window is where tkinter takes the foreground, so the
        # style goes on as soon as there is a handle to put it on, and the
        # focus goes straight back to the window the user is dictating into.
        root.update_idletasks()
        no_activate()
        hand_back()

        frame = tkinter.Frame(root, bg=_BG, padx=20, pady=14)
        frame.pack()
        dot = tkinter.Label(frame, text="●", fg=_DOT["listening"], bg=_BG, font=("Segoe UI", 10))
        dot.pack(side="left", padx=(0, 10))
        message = tkinter.Label(
            frame,
            text="Słucham…",
            fg=_MUTED,
            bg=_BG,
            font=("Segoe UI", 11),
            wraplength=640,
            justify="left",
        )
        message.pack(side="left")

        def place() -> None:
            root.update_idletasks()
            width = root.winfo_reqwidth()
            height = root.winfo_reqheight()
            x = (root.winfo_screenwidth() - width) // 2
            y = root.winfo_screenheight() - height - 90
            root.geometry(f"+{x}+{y}")

        shown = False

        def pump() -> None:
            nonlocal shown
            try:
                while True:
                    item = self._queue.get_nowait()
                    if item is None:
                        root.destroy()
                        return
                    state, text = item
                    dot.configure(fg=_DOT.get(state, _FG))
                    if text:
                        message.configure(text=text, fg=_FG)
                    elif state == "transcribing":
                        message.configure(text="Przetwarzam…", fg=_MUTED)
                    elif state == "listening" and not shown:
                        message.configure(text="Słucham…", fg=_MUTED)
                    if not shown:
                        root.deiconify()
                        # Again, because mapping the window is where Tk gets to
                        # rewrite the style it was given before — and to take
                        # the foreground a second time.
                        no_activate()
                        hand_back()
                        shown = True
                    place()
            except queue.Empty:
                pass
            root.after(120, pump)

        root.after(0, pump)
        try:
            root.mainloop()
        except Exception:
            LOGGER.exception("Okno podglądu zakończyło się błędem")
