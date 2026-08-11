"""Record a chord by pressing it, using a low-level keyboard hook.

Qt's own ``QKeySequenceEdit`` would be a one-line answer, but it only ever sees
keystrokes the shell has already declined to handle — and the shell handles the
Windows key. For an application whose whole job is a global shortcut, a picker
that cannot record ``win+alt+space`` is a picker that hides the best half of the
keyboard.

``WH_KEYBOARD_LL`` sits ahead of everyone. While a capture is running every
keystroke is swallowed, so pressing Win records it instead of opening the Start
menu, and the chord never leaks into whatever window is behind the dialog.

The hook must be installed on a thread that pumps messages. The Qt UI thread
does, which is why :class:`KeyCapture` is driven from the widget and never
spawns a thread of its own — and why ``on_result`` must not unhook inline: it
is called from inside the hook procedure, so the caller defers.
"""

from __future__ import annotations

import logging
from collections.abc import Callable, Iterable

from voiceflow.winplat.hotkey import _MODIFIERS, format_binding

LOGGER = logging.getLogger(__name__)

#: Every virtual key that means "modifier", including the left/right variants
#: a low-level hook reports instead of the merged VK_SHIFT/VK_CONTROL/VK_MENU.
_MODIFIER_VKS = {
    0x10: "shift", 0xA0: "shift", 0xA1: "shift",
    0x11: "ctrl", 0xA2: "ctrl", 0xA3: "ctrl",
    0x12: "alt", 0xA4: "alt", 0xA5: "alt",
    0x5B: "win", 0x5C: "win",
}
_VK_ESCAPE = 0x1B
_WH_KEYBOARD_LL = 13
_WM_KEYDOWN, _WM_SYSKEYDOWN = 0x0100, 0x0104


def binding_from_keys(held: Iterable[int], key: int) -> str | None:
    """Turn "these modifiers are down, this key just went down" into config text.

    Returns ``None`` when the chord is not finished (the key is itself a
    modifier) or cannot be expressed — a media key, a numpad key, anything the
    parser would refuse. Callers show that as "nieobsługiwany klawisz" rather
    than writing a binding the daemon will reject at startup.
    """
    if key in _MODIFIER_VKS:
        return None
    modifiers = 0
    for vk in held:
        name = _MODIFIER_VKS.get(vk)
        if name is not None:
            modifiers |= _MODIFIERS[name]
    try:
        return format_binding(modifiers, key)
    except ValueError:
        return None


class KeyCapture:
    """Swallow the keyboard until one non-modifier key lands.

    ``on_result(binding, cancelled)`` receives the recorded binding, or ``None``
    with ``cancelled=True`` when the user pressed Escape and ``cancelled=False``
    when the key simply cannot be bound — the caller says different things about
    a deliberate escape and an unusable key. It runs inside the hook procedure,
    so it must only schedule work: calling :meth:`stop` from it would unhook a
    hook that is still on the stack.

    One instance records one chord; the settings field builds a fresh one each
    time it enters capture mode.
    """

    def __init__(self, on_result: Callable[[str | None, bool], None]) -> None:
        self.on_result = on_result
        self._held: set[int] = set()
        self._handle = None
        self._proc = None  # the CFUNCTYPE trampoline; a GC'd one crashes Windows
        self._finished = False
        self._user32 = None

    def start(self) -> None:
        """Install the hook. Raises ``OSError`` if Windows refuses."""
        import ctypes
        import ctypes.wintypes as wintypes

        lresult = ctypes.c_ssize_t
        hookproc = ctypes.WINFUNCTYPE(lresult, ctypes.c_int, wintypes.WPARAM, wintypes.LPARAM)

        class KBDLLHOOKSTRUCT(ctypes.Structure):
            _fields_ = [
                ("vkCode", wintypes.DWORD),
                ("scanCode", wintypes.DWORD),
                ("flags", wintypes.DWORD),
                ("time", wintypes.DWORD),
                ("dwExtraInfo", ctypes.c_size_t),
            ]

        # Own handles rather than the shared ctypes.windll ones: use_last_error
        # is what makes a failed hook report why instead of just "nie da się".
        user32 = ctypes.WinDLL("user32", use_last_error=True)  # type: ignore[attr-defined]
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)  # type: ignore[attr-defined]
        # Without these the 64-bit handle and lParam are silently truncated to
        # 32 bits, and the hook either never fires or reads a wild pointer.
        user32.SetWindowsHookExW.restype = wintypes.HHOOK
        user32.SetWindowsHookExW.argtypes = [
            ctypes.c_int, hookproc, wintypes.HINSTANCE, wintypes.DWORD
        ]
        user32.CallNextHookEx.restype = lresult
        user32.CallNextHookEx.argtypes = [
            wintypes.HHOOK, ctypes.c_int, wintypes.WPARAM, wintypes.LPARAM
        ]
        # Same trap on the module handle: ctypes defaults to c_int, which
        # truncates it to 32 bits and makes SetWindowsHookExW fail with 126.
        kernel32.GetModuleHandleW.restype = wintypes.HMODULE
        kernel32.GetModuleHandleW.argtypes = [wintypes.LPCWSTR]

        def callback(code: int, wparam: int, lparam: int) -> int:
            if code < 0:
                return user32.CallNextHookEx(None, code, wparam, lparam)
            info = ctypes.cast(lparam, ctypes.POINTER(KBDLLHOOKSTRUCT)).contents
            self._handle_key(int(info.vkCode), wparam in (_WM_KEYDOWN, _WM_SYSKEYDOWN))
            # Swallow unconditionally, including the key-ups of the chord we
            # just recorded: half a chord arriving in the window behind us is
            # how a picker leaves an application with a stuck modifier.
            return 1

        self._proc = hookproc(callback)
        self._handle = user32.SetWindowsHookExW(
            _WH_KEYBOARD_LL, self._proc, kernel32.GetModuleHandleW(None), 0
        )
        if not self._handle:
            code = ctypes.get_last_error()
            self._proc = None
            raise OSError(
                f"Nie można nasłuchiwać klawiatury (błąd {code}) — "
                "wpisz skrót ręcznie w config.yaml."
            )
        self._user32 = user32
        LOGGER.debug("Nagrywanie skrótu rozpoczęte")

    def stop(self) -> None:
        """Release the keyboard. Safe to call twice, or before :meth:`start`."""
        if self._handle and self._user32 is not None:
            self._user32.UnhookWindowsHookEx(self._handle)
        self._handle = None
        self._proc = None
        self._held.clear()

    def _handle_key(self, vk: int, pressed: bool) -> None:
        if not pressed:
            self._held.discard(vk)
            return
        if self._finished:
            return
        if vk == _VK_ESCAPE:
            self._finish(None, cancelled=True)
        elif vk in _MODIFIER_VKS:
            self._held.add(vk)  # a set, so autorepeat costs nothing
        else:
            self._finish(binding_from_keys(self._held, vk), cancelled=False)

    def _finish(self, binding: str | None, *, cancelled: bool) -> None:
        self._finished = True
        try:
            self.on_result(binding, cancelled)
        except Exception:
            LOGGER.exception("Błąd obsługi nagranego skrótu")
