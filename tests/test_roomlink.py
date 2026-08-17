"""Puls łącza pokoju. Bez sieci — pompa dostaje podstawione gniazdo."""

from __future__ import annotations

import json

from voiceflow.config import RoomConfig
from voiceflow.roomlink import WebSocketTransport


class _Socket:
    """Gniazdo, które najpierw milczy (timeout), potem umiera."""

    def __init__(self, quiet_cycles: int = 1) -> None:
        self.sent: list[str] = []
        self._quiet = quiet_cycles

    def recv(self, timeout: float | None = None) -> str | None:
        if self._quiet > 0:
            self._quiet -= 1
            raise TimeoutError
        return None  # koniec połączenia

    def send(self, payload: str) -> None:
        self.sent.append(payload)


def _transport() -> WebSocketTransport:
    return WebSocketTransport(
        RoomConfig(enabled=True, server="wss://example", code="ROOM01", token="tok")
    )


def test_pulse_flows_while_speaking() -> None:
    transport = _transport()
    transport.is_speaking = lambda: True
    socket = _Socket(quiet_cycles=2)

    transport._pump(socket)  # noqa: SLF001

    beats = [json.loads(raw) for raw in socket.sent]
    assert beats == [{"type": "heartbeat"}] * 2


def test_no_pulse_while_silent() -> None:
    """Serwer rozumie puls jako „wciąż mówię" — odświeża nim wpis mówiącego.
    Puls wysyłany w ciszy podtrzymywał w nieskończoność wpis po zgubionym
    speaking_ended; bez pulsu serwer wygasza go sam po dziesięciu sekundach."""
    transport = _transport()
    transport.is_speaking = lambda: False
    socket = _Socket(quiet_cycles=3)

    transport._pump(socket)  # noqa: SLF001

    assert socket.sent == []


def test_unwired_gate_defaults_to_pulsing() -> None:
    """Transport bez podpiętej bramki (inne wywołania niż demon) musi pulsować:
    brak pulsu ścinałby PRAWDZIWEGO mówiącego po dziesięciu sekundach."""
    transport = _transport()
    socket = _Socket(quiet_cycles=1)

    transport._pump(socket)  # noqa: SLF001

    assert len(socket.sent) == 1
