"""On-screen dictation indicator for Windows, built on tkinter (stdlib).

Same protocol as the Linux overlay controller (``start``/``update``/``stop``),
but in-process: tkinter runs on a dedicated thread with a queue instead of a
child process on the system Python. The window is borderless, always-on-top,
bottom-centered, and — the part that matters — marked ``WS_EX_NOACTIVATE`` so
it can never steal focus from the window that should receive the paste.
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
            self._thread = threading.Thread(
                target=self._run, name="voiceflow-overlay", daemon=True
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

    def _run(self) -> None:  # pragma: no cover - requires a Windows display
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

        def no_activate() -> None:
            try:
                import ctypes

                hwnd = int(root.frame(), 16) if isinstance(root.frame(), str) else root.winfo_id()
                hwnd = ctypes.windll.user32.GetParent(root.winfo_id()) or root.winfo_id()  # type: ignore[attr-defined]
                style = ctypes.windll.user32.GetWindowLongW(hwnd, _GWL_EXSTYLE)  # type: ignore[attr-defined]
                ctypes.windll.user32.SetWindowLongW(  # type: ignore[attr-defined]
                    hwnd, _GWL_EXSTYLE, style | _WS_EX_NOACTIVATE | _WS_EX_TOOLWINDOW
                )
            except Exception:
                LOGGER.exception("Nie udało się ustawić WS_EX_NOACTIVATE")

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
                        no_activate()
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
