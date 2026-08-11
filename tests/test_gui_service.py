"""Tests for the desktop window's service layer (no Qt, no window needed)."""

from __future__ import annotations

import os
import threading
from pathlib import Path

import pytest
import yaml

pytest.importorskip("PySide6", reason="okno pulpitu jest zależnością windowsową")

from voiceflow.gui import service  # noqa: E402


@pytest.fixture
def sandbox(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    target = tmp_path / "config.yaml"
    target.write_text(
        yaml.safe_dump(
            {
                "model": {"name": "small", "device": "cpu", "vocabulary": ["Supabase"]},
                "inject": {"paste_key": "ctrl+shift+v"},
                "sekcja_z_przyszlosci": {"klucz": "wartosc"},
            },
            allow_unicode=True,
        ),
        encoding="utf-8",
    )
    monkeypatch.setattr(service, "config_path", lambda: target)
    return target


def test_update_config_preserves_keys_it_does_not_know(sandbox: Path) -> None:
    """The window is not the only writer; it must not eat settings it predates."""

    def mutate(raw: dict) -> None:
        service.mutable_section(raw, "model")["device"] = "cuda"

    service.update_config(mutate)

    written = yaml.safe_load(sandbox.read_text(encoding="utf-8"))
    assert written["model"]["device"] == "cuda"
    assert written["model"]["name"] == "small"
    assert written["sekcja_z_przyszlosci"] == {"klucz": "wartosc"}


def test_update_config_reads_fresh_rather_than_trusting_a_snapshot(sandbox: Path) -> None:
    """Regression: a page saving its own stale copy reverted the other page."""
    stale = service.load_raw_config()
    assert stale["model"]["device"] == "cpu"

    service.update_config(
        lambda raw: service.mutable_section(raw, "model").__setitem__("device", "cuda")
    )
    # A second writer that only knows about the vocabulary must not undo that.
    service.update_config(
        lambda raw: service.mutable_section(raw, "model").__setitem__(
            "vocabulary", ["Supabase", "Coolify"]
        )
    )

    written = yaml.safe_load(sandbox.read_text(encoding="utf-8"))
    assert written["model"]["device"] == "cuda"
    assert written["model"]["vocabulary"] == ["Supabase", "Coolify"]


def test_concurrent_updates_do_not_lose_each_other(sandbox: Path) -> None:
    """Both pages save from their own worker thread."""
    barrier = threading.Barrier(2)

    def writer(section_name: str, key: str, value: str):
        def run() -> None:
            barrier.wait()
            service.update_config(
                lambda raw: service.mutable_section(raw, section_name).__setitem__(key, value)
            )

        return run

    threads = [
        threading.Thread(target=writer("model", "device", "cuda")),
        threading.Thread(target=writer("inject", "paste_key", "ctrl+v")),
    ]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(timeout=10)

    written = yaml.safe_load(sandbox.read_text(encoding="utf-8"))
    assert written["model"]["device"] == "cuda"
    assert written["inject"]["paste_key"] == "ctrl+v"


def test_config_written_where_the_daemon_reads_it() -> None:
    """The window edits the daemon's own file, not a copy of its own."""
    from voiceflow.paths import config_dir

    assert service.config_path() == config_dir() / "config.yaml"


def test_atomic_write_leaves_no_partial_file_behind(sandbox: Path) -> None:
    service.atomic_write_config({"model": {"name": "tiny"}})

    leftovers = list(sandbox.parent.glob(".config.yaml.*"))
    assert leftovers == []
    assert yaml.safe_load(sandbox.read_text(encoding="utf-8"))["model"]["name"] == "tiny"


def test_written_config_is_still_readable_by_the_daemon(sandbox: Path) -> None:
    """A window save must never produce something parse_config chokes on."""
    from voiceflow.config import parse_config

    service.update_config(
        lambda raw: service.mutable_section(raw, "model").__setitem__("beam_size", 7)
    )

    config = parse_config(yaml.safe_load(sandbox.read_text(encoding="utf-8")))
    assert config.model.beam_size == 7
    assert config.model.name == "small"


def test_value_readers_fall_back_on_junk() -> None:
    junk = {"name": 5, "enabled": "tak", "count": -2, "ratio": None}

    assert service.string_value(junk, "name", "domyślna") == "domyślna"
    assert service.bool_value(junk, "enabled", True) is True
    assert service.int_value(junk, "count", 12) == 12
    assert service.float_value(junk, "ratio", 1.5) == 1.5
    assert service.string_list_value({"vocabulary": "Solo"}, "vocabulary") == ["Solo"]
    assert service.string_list_value({"vocabulary": [1, "  ", "Ok"]}, "vocabulary") == ["Ok"]


def test_duck_rules_reject_out_of_range_volumes() -> None:
    rules = service.float_mapping_value(
        {"duck_rules": {"Spotify": 0.2, "Zły": 4.0, "": 0.5, "Discord": 0.3}}, "duck_rules"
    )

    assert rules == {"Spotify": 0.2, "Discord": 0.3}


def test_probe_recognises_the_shortcut_the_daemon_already_holds(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Our own daemon owns its hotkey, so Windows refuses to lend it to us.

    Without this branch the settings window would tell the user that the
    shortcut they are happily using every day is taken and must be changed.
    """
    monkeypatch.setattr(
        service, "daemon_status", lambda: {"hotkey": "ctrl+shift+space", "hotkey_active": True}
    )

    assert service.probe_binding("ctrl+shift+space") == "current"


def test_probe_still_asks_windows_when_the_daemons_hotkey_is_dead(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A daemon whose registration failed holds nothing — ask, do not assume."""
    monkeypatch.setattr(
        service, "daemon_status", lambda: {"hotkey": "ctrl+shift+space", "hotkey_active": False}
    )
    asked: list[str] = []
    monkeypatch.setattr(
        "voiceflow.winplat.hotkey.binding_is_available",
        lambda binding: asked.append(binding) or True,
    )

    assert service.probe_binding("ctrl+shift+space") == "free"
    assert asked == ["ctrl+shift+space"]


@pytest.mark.skipif(os.name != "nt", reason="uruchamianie demona jest ścieżką windowsową")
def test_daemon_launcher_prefers_a_windowless_interpreter() -> None:
    """Starting the daemon from the window must not flash a console."""
    command = service._daemon_launcher()

    assert command[1:] == ["-m", "voiceflow", "daemon"]
    assert Path(command[0]).name in {"pythonw.exe", "python.exe"}
