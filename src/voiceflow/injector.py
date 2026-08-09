"""Wayland-compatible text injection through ydotool or the clipboard."""

from __future__ import annotations

import logging
import os
import shutil
import socket
import subprocess
import tempfile
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

from voiceflow.config import InjectConfig
from voiceflow.paths import ydotool_socket_path

LOGGER = logging.getLogger(__name__)


class InjectionError(RuntimeError):
    """Raised when text cannot be delivered to the active application."""


@dataclass(frozen=True, slots=True)
class ProbeResult:
    """Human-readable injection dependency diagnostics."""

    ydotool_binary: bool
    ydotool_socket: str
    ydotool_socket_responding: bool
    uinput_writable: bool
    wl_copy_binary: bool
    wl_paste_binary: bool
    summary: str

    def to_dict(self) -> dict[str, Any]:
        """Return a JSON-serializable representation."""
        return asdict(self)


@dataclass(frozen=True, slots=True)
class InjectionResult:
    """Describe the method used and whether fallback was necessary."""

    method: str
    fallback_reason: str | None = None


# evdev keycodes from linux/input-event-codes.h. Letters are laid out by QWERTY
# row, not alphabetically, so every entry is spelled out rather than computed.
_KEY_CODES: dict[str, int] = {
    "a": 30, "b": 48, "c": 46, "d": 32, "e": 18, "f": 33,
    "g": 34, "h": 35, "i": 23, "j": 36, "k": 37, "l": 38,
    "m": 50, "n": 49, "o": 24, "p": 25, "q": 16, "r": 19,
    "s": 31, "t": 20, "u": 22, "v": 47, "w": 17, "x": 45,
    "y": 21, "z": 44,
    "enter": 28, "tab": 15, "space": 57, "insert": 110,
}
_MODIFIER_CODES = {"ctrl": 29, "control": 29, "shift": 42, "alt": 56, "super": 125, "meta": 125}


def build_type_command(binary: str, key_delay_ms: int, text: str) -> list[str]:
    """Build a safe ydotool type command, preserving leading hyphens and UTF-8."""
    return [binary, "type", "--key-delay", str(key_delay_ms), "--", text]


def build_key_command(binary: str, chord: str) -> list[str]:
    """Translate a configurable key chord to ydotool evdev press/release pairs."""
    parts = [part.strip().lower() for part in chord.split("+") if part.strip()]
    if len(parts) < 1:
        raise InjectionError("Skrót wklejania jest pusty")
    codes: list[int] = []
    for part in parts[:-1]:
        code = _MODIFIER_CODES.get(part)
        if code is None:
            raise InjectionError(f"Nieznany modyfikator skrótu wklejania: {part}")
        codes.append(code)
    key = _KEY_CODES.get(parts[-1])
    if key is None:
        raise InjectionError(f"Nieznany klawisz skrótu wklejania: {parts[-1]}")
    codes.append(key)
    events = [f"{code}:1" for code in codes]
    events.extend(f"{code}:0" for code in reversed(codes))
    return [binary, "key", *events]


class Injector:
    """Inject text using the configured Wayland-safe strategy."""

    def __init__(self, config: InjectConfig) -> None:
        self.config = config

    @staticmethod
    def _environment() -> dict[str, str]:
        environment = os.environ.copy()
        environment.setdefault("YDOTOOL_SOCKET", str(ydotool_socket_path()))
        return environment

    def inject(self, text: str) -> InjectionResult:
        """Inject non-empty text and return the selected delivery method."""
        if not text:
            raise InjectionError("Tekst do wpisania jest pusty")
        if self.config.method == "clipboard":
            self._inject_clipboard(text)
            return InjectionResult("clipboard")
        if not text.isascii():
            # ydotool 1.0.4's type command has a fixed 128-entry ASCII map and
            # silently drops UTF-8 bytes. Use the clipboard before data can be
            # lost, including when the configured default is "ydotool".
            reason = "ydotool 1.0.4 nie obsługuje znaków spoza ASCII"
            LOGGER.info("%s; używam bezpiecznej ścieżki schowkowej", reason)
            self._inject_clipboard(text)
            return InjectionResult("clipboard", reason)
        try:
            self._inject_ydotool(text)
            return InjectionResult("ydotool")
        except InjectionError as exc:
            if self.config.method != "auto":
                raise
            LOGGER.warning("ydotool nie zadziałał, używam schowka: %s", exc)
            self._inject_clipboard(text)
            return InjectionResult("clipboard", str(exc))

    def _inject_ydotool(self, text: str) -> None:
        binary = shutil.which("ydotool")
        if binary is None:
            raise InjectionError("Nie znaleziono programu ydotool")
        command = build_type_command(binary, self.config.key_delay_ms, text)
        self._run(command, environment=self._environment(), timeout=30)

    def _inject_clipboard(self, text: str) -> None:
        wl_copy = shutil.which("wl-copy")
        ydotool = shutil.which("ydotool")
        if wl_copy is None:
            raise InjectionError("Nie znaleziono programu wl-copy")
        if ydotool is None:
            raise InjectionError("Nie znaleziono programu ydotool potrzebnego do wklejenia")

        previous: bytes | None = None
        wl_paste = shutil.which("wl-paste")
        if self.config.restore_clipboard and wl_paste is not None:
            try:
                previous = self._capture([wl_paste, "--no-newline"], timeout=3)
            except InjectionError as exc:
                LOGGER.info("Nie udało się odczytać poprzedniego schowka: %s", exc)

        self._run([wl_copy], input_data=text.encode("utf-8"), timeout=3)
        paste_command = build_key_command(ydotool, self.config.paste_key)
        self._run(paste_command, environment=self._environment(), timeout=5)

        if previous is not None:
            # Give the focused application time to request the clipboard before
            # replacing the selection with its original contents.
            time.sleep(0.15)
            try:
                self._run([wl_copy], input_data=previous, timeout=3)
            except InjectionError as exc:
                LOGGER.warning("Nie udało się przywrócić schowka: %s", exc)

    @staticmethod
    def _run(
        command: list[str],
        *,
        input_data: bytes | None = None,
        environment: dict[str, str] | None = None,
        timeout: float,
    ) -> None:
        # Deliberately no stdout/stderr pipes. wl-copy forks a child that owns the
        # Wayland selection for as long as the clipboard holds it, and that child
        # inherits the pipe write ends. subprocess.run() waits for EOF on them, so
        # piping here made every single paste time out. Temporary files cannot be
        # held open against us and still preserve the diagnostics.
        try:
            with tempfile.TemporaryFile() as stderr_file:
                process = subprocess.Popen(
                    command,
                    stdin=subprocess.PIPE if input_data is not None else subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL,
                    stderr=stderr_file,
                    env=environment,
                    shell=False,
                )
                try:
                    if process.stdin is not None:
                        process.stdin.write(input_data or b"")
                        process.stdin.close()
                    return_code = process.wait(timeout=timeout)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=2)
                    raise
                if return_code != 0:
                    stderr_file.seek(0)
                    detail = stderr_file.read().decode(errors="replace").strip()
                    raise InjectionError(
                        f"{Path(command[0]).name} zakończył się kodem {return_code}: {detail}"
                    )
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise InjectionError(f"Nie można wykonać {command[0]}: {exc}") from exc

    @staticmethod
    def _capture(command: list[str], *, timeout: float) -> bytes:
        try:
            result = subprocess.run(
                command,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
                timeout=timeout,
                shell=False,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise InjectionError(f"Nie można wykonać {command[0]}: {exc}") from exc
        if result.returncode != 0:
            detail = result.stderr.decode(errors="replace").strip()
            raise InjectionError(f"{Path(command[0]).name}: {detail or 'brak danych w schowku'}")
        return result.stdout

    def probe(self) -> ProbeResult:
        """Inspect binaries, the ydotool socket, and uinput permissions."""
        ydotool = shutil.which("ydotool") is not None
        wl_copy = shutil.which("wl-copy") is not None
        wl_paste = shutil.which("wl-paste") is not None
        socket_path = ydotool_socket_path()
        responding = _probe_unix_socket(socket_path)
        uinput_writable = os.access("/dev/uinput", os.W_OK)
        issues: list[str] = []
        if not ydotool:
            issues.append("brak ydotool")
        if not responding:
            issues.append(f"socket {socket_path} nie odpowiada")
        if not uinput_writable:
            issues.append("brak prawa zapisu do /dev/uinput")
        if not wl_copy:
            issues.append("brak wl-copy")
        summary = "Gotowe" if not issues else "; ".join(issues)
        return ProbeResult(ydotool, str(socket_path), responding, uinput_writable, wl_copy, wl_paste, summary)


def _probe_unix_socket(path: Path) -> bool:
    if not path.exists():
        return False
    for socket_type in (socket.SOCK_STREAM, socket.SOCK_DGRAM):
        probe_socket = socket.socket(socket.AF_UNIX, socket_type)
        probe_socket.settimeout(0.2)
        try:
            probe_socket.connect(str(path))
            return True
        except OSError:
            continue
        finally:
            probe_socket.close()
    return False
