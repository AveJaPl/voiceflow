"""Tests for the loopback IPC transport the Windows daemon speaks.

Loopback TCP works on every platform, so these run everywhere — the Windows
branch of ``send_request`` is exercised on Linux CI too by flipping the module
flag rather than by hoping someone runs the suite on Windows.
"""

from __future__ import annotations

import json
import socket
import threading
from collections.abc import Iterator
from pathlib import Path

import pytest

from voiceflow import daemon as daemon_module
from voiceflow.daemon import (
    DaemonAlreadyRunning,
    _read_endpoint,
    _remove_stale_endpoint,
    _RequestHandler,
    _TcpServer,
    _write_endpoint,
    send_request,
)

TOKEN = "0123456789abcdef"


class _StubDaemon:
    """Stands in for the real daemon: records what the transport delivered."""

    def __init__(self) -> None:
        self.commands: list[str] = []

    def handle_command(self, command: str) -> dict[str, object]:
        self.commands.append(command)
        return {"ok": True, "message": "pong", "state": "IDLE"}


def _serve(token: str | None) -> tuple[_TcpServer, _StubDaemon]:
    stub = _StubDaemon()
    server = _TcpServer(("127.0.0.1", 0), _RequestHandler)
    server.voiceflow_daemon = stub  # type: ignore[attr-defined]
    if token is not None:
        server.voiceflow_token = token  # type: ignore[attr-defined]
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, stub


@pytest.fixture
def guarded() -> Iterator[tuple[_TcpServer, _StubDaemon]]:
    server, stub = _serve(TOKEN)
    yield server, stub
    server.shutdown()
    server.server_close()


def _raw_request(port: int, payload: dict[str, object]) -> dict[str, object]:
    client = socket.create_connection(("127.0.0.1", port), timeout=2)
    try:
        client.sendall(json.dumps(payload).encode("utf-8") + b"\n")
        with client.makefile("rb") as response:
            return json.loads(response.readline())
    finally:
        client.close()


def test_endpoint_file_round_trips(tmp_path: Path) -> None:
    path = tmp_path / "daemon.json"

    _write_endpoint(path, 54321, TOKEN)

    assert _read_endpoint(path) == (54321, TOKEN)


def test_missing_endpoint_reads_as_daemon_not_running(tmp_path: Path) -> None:
    with pytest.raises(RuntimeError, match="nie działa"):
        _read_endpoint(tmp_path / "absent.json")


def test_corrupt_endpoint_does_not_crash_the_client(tmp_path: Path) -> None:
    path = tmp_path / "daemon.json"
    path.write_text("{not json", encoding="utf-8")

    with pytest.raises(RuntimeError, match="nie działa"):
        _read_endpoint(path)


def test_client_reaches_the_daemon_over_loopback(
    guarded: tuple[_TcpServer, _StubDaemon], tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    server, stub = guarded
    endpoint = tmp_path / "daemon.json"
    _write_endpoint(endpoint, server.server_address[1], TOKEN)
    monkeypatch.setattr(daemon_module, "_WINDOWS", True)

    response = send_request("toggle", socket_path=endpoint, timeout=2.0)

    assert response["ok"] is True
    assert stub.commands == ["toggle"]


def test_request_without_the_token_is_refused(
    guarded: tuple[_TcpServer, _StubDaemon]
) -> None:
    """Loopback is reachable by every local process; the token is the door."""
    server, stub = guarded

    response = _raw_request(server.server_address[1], {"command": "start"})

    assert response["ok"] is False
    assert stub.commands == []


def test_request_with_a_wrong_token_is_refused(
    guarded: tuple[_TcpServer, _StubDaemon]
) -> None:
    server, stub = guarded

    response = _raw_request(
        server.server_address[1], {"command": "start", "token": "wrong-token-xxx"}
    )

    assert response["ok"] is False
    assert stub.commands == []


def test_a_live_daemon_blocks_a_second_one(
    guarded: tuple[_TcpServer, _StubDaemon], tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Two daemons means two copies of the model and a hotkey owned by chance."""
    server, _ = guarded
    endpoint = tmp_path / "daemon.json"
    _write_endpoint(endpoint, server.server_address[1], TOKEN)
    monkeypatch.setattr(daemon_module, "_WINDOWS", True)

    with pytest.raises(DaemonAlreadyRunning):
        _remove_stale_endpoint(endpoint)

    assert endpoint.exists(), "the live daemon's endpoint must survive the check"


def test_an_endpoint_left_by_a_dead_daemon_is_cleared(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A crash leaves the file behind; refusing to start then would be a deadlock."""
    endpoint = tmp_path / "daemon.json"
    # Port 1 on loopback answers nothing, standing in for a daemon that died.
    _write_endpoint(endpoint, 1, TOKEN)
    monkeypatch.setattr(daemon_module, "_WINDOWS", True)

    _remove_stale_endpoint(endpoint)

    assert not endpoint.exists()


def test_server_without_a_token_accepts_plain_requests() -> None:
    """The unix-socket server relies on 0600 instead and sets no token."""
    server, stub = _serve(None)
    try:
        response = _raw_request(server.server_address[1], {"command": "ping"})
    finally:
        server.shutdown()
        server.server_close()

    assert response["ok"] is True
    assert stub.commands == ["ping"]
