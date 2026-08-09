"""Global hotkey on Windows via RegisterHotKey.

On GNOME the hotkey lives outside the process (a gsettings binding runs the
thin client). Windows flips this around: the daemon registers the hotkey
itself and no client process is needed — pressing it calls straight into the
daemon's toggle. RegisterHotKey must be called on the same thread that runs
the message loop, so both live on one dedicated thread here.
"""

from __future__ import annotations

import logging
import threading
from collections.abc import Callable

LOGGER = logging.getLogger(__name__)

_MODIFIERS = {"alt": 0x0001, "ctrl": 0x0002, "shift": 0x0004, "win": 0x0008}
#: Non-character keys accepted in a binding.
_NAMED_KEYS = {"space": 0x20, "insert": 0x2D, "pause": 0x13, "f9": 0x78, "f10": 0x79}
_WM_HOTKEY = 0x0312
_HOTKEY_ID = 0xBEEF


def parse_binding(binding: str) -> tuple[int, int]:
    """Translate ``ctrl+shift+space`` into (modifier mask, virtual key).

    Pure and testable everywhere. Letters and digits map through their
    uppercase ordinal, which is exactly the WinAPI virtual-key convention.
    """
    modifiers = 0
    key: int | None = None
    for part in binding.lower().split("+"):
        part = part.strip()
        if part in _MODIFIERS:
            modifiers |= _MODIFIERS[part]
        elif part in _NAMED_KEYS:
            key = _NAMED_KEYS[part]
        elif len(part) == 1 and (part.isalpha() or part.isdigit()):
            key = ord(part.upper())
        else:
            raise ValueError(f"Nieznany klawisz w skrócie: {part!r}")
    if key is None:
        raise ValueError(f"Skrót {binding!r} nie zawiera klawisza głównego")
    return modifiers, key


class HotkeyListener:
    """Own thread: RegisterHotKey + GetMessage loop, firing a callback."""

    def __init__(self, binding: str, callback: Callable[[], None]) -> None:
        self.binding = binding
        self.callback = callback
        self._thread: threading.Thread | None = None
        self._thread_id: int | None = None

    def start(self) -> None:
        thread = threading.Thread(target=self._run, name="voiceflow-hotkey", daemon=True)
        self._thread = thread
        thread.start()

    def stop(self) -> None:
        if self._thread_id is not None:
            import ctypes

            # WM_QUIT ends GetMessageW; UnregisterHotKey happens in the loop's finally.
            ctypes.windll.user32.PostThreadMessageW(self._thread_id, 0x0012, 0, 0)  # type: ignore[attr-defined]
        if self._thread is not None:
            self._thread.join(timeout=2)

    def _run(self) -> None:  # pragma: no cover - requires a Windows message queue
        import ctypes
        import ctypes.wintypes as wintypes

        user32 = ctypes.windll.user32  # type: ignore[attr-defined]
        kernel32 = ctypes.windll.kernel32  # type: ignore[attr-defined]
        self._thread_id = kernel32.GetCurrentThreadId()
        modifiers, key = parse_binding(self.binding)
        if not user32.RegisterHotKey(None, _HOTKEY_ID, modifiers, key):
            LOGGER.error(
                "Nie można zarejestrować skrótu %s — zajęty przez inną aplikację?",
                self.binding,
            )
            return
        LOGGER.info("Skrót globalny aktywny: %s", self.binding)
        message = wintypes.MSG()
        try:
            while user32.GetMessageW(ctypes.byref(message), None, 0, 0) > 0:
                if message.message == _WM_HOTKEY:
                    try:
                        self.callback()
                    except Exception:
                        LOGGER.exception("Błąd obsługi skrótu")
        finally:
            user32.UnregisterHotKey(None, _HOTKEY_ID)
