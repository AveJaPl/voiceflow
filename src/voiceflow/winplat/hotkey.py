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
_NAMED_KEYS = {
    "space": 0x20,
    "insert": 0x2D,
    "pause": 0x13,
    "f1": 0x70, "f2": 0x71, "f3": 0x72, "f4": 0x73,
    "f5": 0x74, "f6": 0x75, "f7": 0x76, "f8": 0x77,
    "f9": 0x78, "f10": 0x79, "f11": 0x7A, "f12": 0x7B,
}
#: Without MOD_NOREPEAT, holding the chord down autorepeats WM_HOTKEY and the
#: daemon flips between recording and transcribing dozens of times a second.
_MOD_NOREPEAT = 0x4000
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

    def __init__(
        self,
        binding: str,
        callback: Callable[[], None],
        *,
        on_error: Callable[[str], None] | None = None,
    ) -> None:
        self.binding = binding
        self.callback = callback
        self.on_error = on_error
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
        try:
            modifiers, key = parse_binding(self.binding)
        except ValueError as exc:
            self._report(f"Nieprawidłowy skrót w konfiguracji: {exc}")
            return
        if not user32.RegisterHotKey(None, _HOTKEY_ID, modifiers | _MOD_NOREPEAT, key):
            # A dead hotkey is the one failure the user cannot diagnose: nothing
            # happens when they press it, and the daemon looks perfectly healthy.
            self._report(
                f"Nie można zarejestrować skrótu {self.binding} — "
                "zajmuje go inna aplikacja. Zmień hotkey.binding w config.yaml."
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

    def _report(self, message: str) -> None:
        LOGGER.error("%s", message)
        if self.on_error is None:
            return
        try:
            self.on_error(message)
        except Exception:
            LOGGER.exception("Nie udało się zgłosić błędu skrótu")
