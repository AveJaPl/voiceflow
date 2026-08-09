"""Text injection on Windows: clipboard + a synthesized paste chord.

Same contract as the Linux injector (``inject(text) -> InjectionResult``,
``probe()``), same philosophy: the clipboard route is the only one that is
safe for every language, and the previous clipboard text is put back after
the paste. All WinAPI access goes through ctypes, loaded lazily so this
module imports cleanly on Linux for tests.
"""

from __future__ import annotations

import logging
import time
from dataclasses import dataclass

from voiceflow.config import InjectConfig

LOGGER = logging.getLogger(__name__)

#: Virtual-key codes for the configurable paste chord (subset that makes sense).
_VIRTUAL_KEYS = {
    "ctrl": 0x11,
    "shift": 0x10,
    "alt": 0x12,
    "win": 0x5B,
    "v": 0x56,
    "insert": 0x2D,
    "enter": 0x0D,
    "tab": 0x09,
    "space": 0x20,
}
_KEYEVENTF_KEYUP = 0x0002
_CF_UNICODETEXT = 13
_GMEM_MOVEABLE = 0x0002


class InjectionError(RuntimeError):
    """Raised when the transcription cannot be delivered."""


@dataclass(frozen=True, slots=True)
class InjectionResult:
    method: str
    fallback_reason: str | None = None


@dataclass(frozen=True, slots=True)
class ProbeResult:
    clipboard: bool
    send_input: bool
    summary: str

    def to_dict(self) -> dict:
        return {
            "clipboard": self.clipboard,
            "send_input": self.send_input,
            "summary": self.summary,
        }


def parse_paste_chord(paste_key: str) -> list[int]:
    """Translate e.g. ``ctrl+v`` into an ordered list of virtual-key codes.

    Pure and testable everywhere. Raises ``InjectionError`` on unknown keys so
    a config typo surfaces as a clear message, not a silent dead hotkey.
    """
    codes: list[int] = []
    for part in paste_key.lower().split("+"):
        part = part.strip()
        if part not in _VIRTUAL_KEYS:
            raise InjectionError(f"Nieznany klawisz w paste_key: {part!r}")
        codes.append(_VIRTUAL_KEYS[part])
    if not codes:
        raise InjectionError("Pusty paste_key")
    return codes


class WinInjector:
    """Clipboard-based injection for Windows."""

    def __init__(self, config: InjectConfig) -> None:
        self.config = config

    def inject(self, text: str) -> InjectionResult:
        previous = None
        if self.config.restore_clipboard:
            try:
                previous = _get_clipboard_text()
            except OSError as exc:
                LOGGER.info("Nie udało się odczytać poprzedniego schowka: %s", exc)
        _set_clipboard_text(text)
        # Windows terminals paste with ctrl+v (Windows Terminal, VS Code);
        # honour the configured chord but default sensibly.
        chord = self.config.paste_key or "ctrl+v"
        try:
            _send_chord(parse_paste_chord(chord))
        except InjectionError:
            raise
        except OSError as exc:
            # The text stays in the clipboard on purpose: recoverable by hand.
            raise InjectionError(
                f"Nie można wysłać {chord} (tekst został w schowku): {exc}"
            ) from exc
        if previous is not None:
            time.sleep(0.15)
            try:
                _set_clipboard_text(previous)
            except OSError as exc:
                LOGGER.warning("Nie udało się przywrócić schowka: %s", exc)
        return InjectionResult("clipboard")

    def probe(self) -> ProbeResult:
        try:
            _get_clipboard_text()
            clipboard = True
        except OSError:
            clipboard = False
        return ProbeResult(clipboard, True, "Gotowe" if clipboard else "Schowek niedostępny")


# -- WinAPI plumbing (lazy ctypes; Windows only) -----------------------------


def _user32():
    import ctypes

    return ctypes.windll.user32  # type: ignore[attr-defined]


def _kernel32():
    import ctypes

    return ctypes.windll.kernel32  # type: ignore[attr-defined]


def _clipboard_session(user32) -> None:
    # OpenClipboard can transiently fail while another app holds it.
    for _attempt in range(5):
        if user32.OpenClipboard(None):
            return
        time.sleep(0.05)
    raise OSError("Nie można otworzyć schowka")


def _get_clipboard_text() -> str | None:
    import ctypes

    user32, kernel32 = _user32(), _kernel32()
    _clipboard_session(user32)
    try:
        handle = user32.GetClipboardData(_CF_UNICODETEXT)
        if not handle:
            return None
        pointer = kernel32.GlobalLock(handle)
        if not pointer:
            return None
        try:
            return ctypes.wstring_at(pointer)
        finally:
            kernel32.GlobalUnlock(handle)
    finally:
        user32.CloseClipboard()


def _set_clipboard_text(text: str) -> None:
    import ctypes

    user32, kernel32 = _user32(), _kernel32()
    buffer = ctypes.create_unicode_buffer(text)
    size = ctypes.sizeof(buffer)
    handle = kernel32.GlobalAlloc(_GMEM_MOVEABLE, size)
    if not handle:
        raise OSError("GlobalAlloc nie powiódł się")
    pointer = kernel32.GlobalLock(handle)
    ctypes.memmove(pointer, buffer, size)
    kernel32.GlobalUnlock(handle)
    _clipboard_session(user32)
    try:
        user32.EmptyClipboard()
        if not user32.SetClipboardData(_CF_UNICODETEXT, handle):
            kernel32.GlobalFree(handle)
            raise OSError("SetClipboardData nie powiódł się")
    finally:
        user32.CloseClipboard()


def _send_chord(codes: list[int]) -> None:
    user32 = _user32()
    for code in codes:
        user32.keybd_event(code, 0, 0, 0)
    for code in reversed(codes):
        user32.keybd_event(code, 0, _KEYEVENTF_KEYUP, 0)
