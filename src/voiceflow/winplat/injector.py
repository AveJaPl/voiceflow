"""Text injection on Windows: clipboard + a synthesized paste chord.

Same contract as the Linux injector (``inject(text) -> InjectionResult``,
``probe()``), same philosophy: the clipboard route is the only one that is
safe for every language, and the previous clipboard text is put back after
the paste. All WinAPI access goes through ctypes, loaded lazily so this
module imports cleanly on Linux for tests.

Two Win32 details this file exists to get right:

* Every handle-returning call declares its ``restype``. ctypes assumes ``int``
  otherwise, which silently truncates a 64-bit ``HANDLE``/``LPVOID`` to 32
  bits — the resulting ``memmove`` writes into nowhere and takes the daemon
  down with an access violation.
* Modifiers the user is still physically holding are released before the
  chord is sent. The hotkey that ends a dictation is itself Ctrl+Shift+Space,
  so without this the OS sees Ctrl+Shift+V where Ctrl+V was intended.
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
#: Side-specific modifier keys checked before pasting. GetAsyncKeyState reports
#: the generic VK_CONTROL/VK_SHIFT/VK_MENU too, but a keyup must name the side.
_HELD_MODIFIERS = {
    0xA0: 0x10,  # VK_LSHIFT   -> shift
    0xA1: 0x10,  # VK_RSHIFT   -> shift
    0xA2: 0x11,  # VK_LCONTROL -> ctrl
    0xA3: 0x11,  # VK_RCONTROL -> ctrl
    0xA4: 0x12,  # VK_LMENU    -> alt
    0xA5: 0x12,  # VK_RMENU    -> alt
    0x5B: 0x5B,  # VK_LWIN
    0x5C: 0x5B,  # VK_RWIN
}
_KEYEVENTF_KEYUP = 0x0002
_INPUT_KEYBOARD = 1
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
        if config.paste_key == "ctrl+shift+v":
            # A config written by an older build carries the Linux default. The
            # file stays authoritative — someone dictating into Windows Terminal
            # may want exactly this — but silence here looks like a dead hotkey.
            LOGGER.warning(
                "paste_key=ctrl+shift+v pochodzi z ustawień linuksowych i jest "
                "ignorowany przez większość aplikacji Windows. Ustaw "
                "inject.paste_key: ctrl+v w config.yaml, jeśli tekst się nie wkleja."
            )

    def inject(self, text: str) -> InjectionResult:
        previous = None
        if self.config.restore_clipboard:
            try:
                previous = _get_clipboard_text()
            except OSError as exc:
                LOGGER.info("Nie udało się odczytać poprzedniego schowka: %s", exc)
        _set_clipboard_text(text)
        chord = self.config.paste_key or "ctrl+v"
        codes = parse_paste_chord(chord)
        try:
            _release_foreign_modifiers(codes)
            _send_chord(codes, self.config.key_delay_ms / 1000.0)
        except OSError as exc:
            # The text stays in the clipboard on purpose: recoverable by hand.
            raise InjectionError(
                f"Nie można wysłać {chord} (tekst został w schowku): {exc}"
            ) from exc
        if previous is not None:
            # The paste is asynchronous: the target app reads the clipboard on
            # its own message loop, so restoring too eagerly pastes the *old*
            # text. A quarter second is imperceptible and comfortably enough.
            time.sleep(0.25)
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
        try:
            parse_paste_chord(self.config.paste_key or "ctrl+v")
            chord_ok, chord_problem = True, ""
        except InjectionError as exc:
            chord_ok, chord_problem = False, str(exc)
        if clipboard and chord_ok:
            summary = "Gotowe"
        elif not clipboard:
            summary = "Schowek niedostępny"
        else:
            summary = chord_problem
        return ProbeResult(clipboard, chord_ok, summary)


# -- WinAPI plumbing (lazy ctypes; Windows only) -----------------------------


def _user32():
    import ctypes

    user32 = ctypes.windll.user32  # type: ignore[attr-defined]
    user32.OpenClipboard.restype = ctypes.c_bool
    user32.CloseClipboard.restype = ctypes.c_bool
    user32.EmptyClipboard.restype = ctypes.c_bool
    user32.IsClipboardFormatAvailable.restype = ctypes.c_bool
    # HANDLE-returning calls: without an explicit restype ctypes hands back a
    # 32-bit int and the upper half of the pointer is gone.
    user32.GetClipboardData.restype = ctypes.c_void_p
    user32.GetClipboardData.argtypes = [ctypes.c_uint]
    user32.SetClipboardData.restype = ctypes.c_void_p
    user32.SetClipboardData.argtypes = [ctypes.c_uint, ctypes.c_void_p]
    user32.GetAsyncKeyState.restype = ctypes.c_short
    user32.GetAsyncKeyState.argtypes = [ctypes.c_int]
    return user32


def _kernel32():
    import ctypes

    kernel32 = ctypes.windll.kernel32  # type: ignore[attr-defined]
    kernel32.GlobalAlloc.restype = ctypes.c_void_p
    kernel32.GlobalAlloc.argtypes = [ctypes.c_uint, ctypes.c_size_t]
    kernel32.GlobalLock.restype = ctypes.c_void_p
    kernel32.GlobalLock.argtypes = [ctypes.c_void_p]
    kernel32.GlobalUnlock.restype = ctypes.c_bool
    kernel32.GlobalUnlock.argtypes = [ctypes.c_void_p]
    kernel32.GlobalFree.restype = ctypes.c_void_p
    kernel32.GlobalFree.argtypes = [ctypes.c_void_p]
    return kernel32


def _open_clipboard(user32) -> None:
    # OpenClipboard can transiently fail while another app holds it.
    for _attempt in range(10):
        if user32.OpenClipboard(None):
            return
        time.sleep(0.05)
    raise OSError("Nie można otworzyć schowka")


def _get_clipboard_text() -> str | None:
    import ctypes

    user32, kernel32 = _user32(), _kernel32()
    if not user32.IsClipboardFormatAvailable(_CF_UNICODETEXT):
        return None
    _open_clipboard(user32)
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
    # Open before allocating: a failure to open would otherwise leak the block,
    # and after SetClipboardData succeeds the system owns it and must not be freed.
    _open_clipboard(user32)
    handle = None
    try:
        handle = kernel32.GlobalAlloc(_GMEM_MOVEABLE, size)
        if not handle:
            raise OSError("GlobalAlloc nie powiódł się")
        pointer = kernel32.GlobalLock(handle)
        if not pointer:
            raise OSError("GlobalLock nie powiódł się")
        ctypes.memmove(pointer, buffer, size)
        kernel32.GlobalUnlock(handle)
        user32.EmptyClipboard()
        if not user32.SetClipboardData(_CF_UNICODETEXT, handle):
            raise OSError("SetClipboardData nie powiódł się")
        handle = None  # ownership transferred to the clipboard
    finally:
        if handle:
            kernel32.GlobalFree(handle)
        user32.CloseClipboard()


def modifiers_to_release(codes: list[int], pressed: set[int]) -> list[int]:
    """Pick the held modifier keys that would corrupt the chord.

    Pure, so the decision is testable without a Windows input queue: a modifier
    is released only when it is physically down *and* not part of the chord.
    """
    wanted = set(codes)
    return [
        physical
        for physical, generic in _HELD_MODIFIERS.items()
        if physical in pressed and generic not in wanted
    ]


def _release_foreign_modifiers(codes: list[int]) -> None:
    """Release modifiers the user is still holding that are not in the chord.

    The dictation-ending hotkey is itself a modifier chord, so on a fast
    machine the paste can fire while Ctrl+Shift are still down — turning
    Ctrl+V into Ctrl+Shift+V, which most Windows apps ignore.
    """
    user32 = _user32()
    pressed = {key for key in _HELD_MODIFIERS if user32.GetAsyncKeyState(key) & 0x8000}
    stuck = modifiers_to_release(codes, pressed)
    for physical in stuck:
        _send_key(physical, up=True)
    if stuck:
        # Give the input queue a moment to settle before the chord goes in.
        time.sleep(0.02)


def _send_chord(codes: list[int], key_delay: float) -> None:
    for code in codes:
        _send_key(code, up=False)
        if key_delay:
            time.sleep(key_delay)
    for code in reversed(codes):
        _send_key(code, up=True)
        if key_delay:
            time.sleep(key_delay)


def _send_key(code: int, *, up: bool) -> None:
    import ctypes

    input_type = _input_structure()
    user32 = ctypes.windll.user32  # type: ignore[attr-defined]
    # A scan code alongside the virtual key keeps games and Electron apps
    # happy; they often read the scan code and ignore a bare virtual key.
    scan = user32.MapVirtualKeyW(code, 0)
    event = input_type()
    event.type = _INPUT_KEYBOARD
    event.union.keyboard.wVk = code
    event.union.keyboard.wScan = scan
    event.union.keyboard.dwFlags = _KEYEVENTF_KEYUP if up else 0
    event.union.keyboard.time = 0
    event.union.keyboard.dwExtraInfo = None
    sent = user32.SendInput(1, ctypes.byref(event), ctypes.sizeof(input_type))
    if sent != 1:
        raise OSError(f"SendInput odrzucił zdarzenie klawisza {code:#x}")


_INPUT_CACHE: type | None = None


def _input_structure() -> type:
    """Define INPUT/KEYBDINPUT lazily and cache them.

    ``ctypes.wintypes`` cannot even be imported on Linux, so the structures
    must not exist at module import time — the test suite imports this module
    everywhere to prove the platform layer stays lazy.
    """
    global _INPUT_CACHE
    if _INPUT_CACHE is not None:
        return _INPUT_CACHE

    import ctypes
    import ctypes.wintypes as wintypes

    class _KeyboardInput(ctypes.Structure):
        _fields_ = [
            ("wVk", wintypes.WORD),
            ("wScan", wintypes.WORD),
            ("dwFlags", wintypes.DWORD),
            ("time", wintypes.DWORD),
            ("dwExtraInfo", ctypes.POINTER(ctypes.c_ulong)),
        ]

    class _MouseInput(ctypes.Structure):
        _fields_ = [
            ("dx", wintypes.LONG),
            ("dy", wintypes.LONG),
            ("mouseData", wintypes.DWORD),
            ("dwFlags", wintypes.DWORD),
            ("time", wintypes.DWORD),
            ("dwExtraInfo", ctypes.POINTER(ctypes.c_ulong)),
        ]

    class _HardwareInput(ctypes.Structure):
        _fields_ = [
            ("uMsg", wintypes.DWORD),
            ("wParamL", wintypes.WORD),
            ("wParamH", wintypes.WORD),
        ]

    class _InputUnion(ctypes.Union):
        _fields_ = [
            ("keyboard", _KeyboardInput),
            ("mouse", _MouseInput),
            ("hardware", _HardwareInput),
        ]

    class _Input(ctypes.Structure):
        _fields_ = [("type", wintypes.DWORD), ("union", _InputUnion)]

    user32 = ctypes.windll.user32  # type: ignore[attr-defined]
    user32.SendInput.restype = ctypes.c_uint
    user32.SendInput.argtypes = [ctypes.c_uint, ctypes.POINTER(_Input), ctypes.c_int]
    user32.MapVirtualKeyW.restype = ctypes.c_uint
    user32.MapVirtualKeyW.argtypes = [ctypes.c_uint, ctypes.c_uint]
    _INPUT_CACHE = _Input
    return _Input
