"""Tests for the daily update check (no network involved)."""

from __future__ import annotations

import json

from voiceflow.config import UpdatesConfig, parse_config
from voiceflow import updates


def test_version_comparison() -> None:
    assert updates.is_newer("v0.3.0", "0.2.1")
    assert updates.is_newer("1.0.0", "0.9.9")
    assert not updates.is_newer("0.2.1", "0.2.1")
    assert not updates.is_newer("v0.2.0", "0.2.1")
    assert updates.parse_version("v1.2.3-beta") == (1, 2, 3)
    assert updates.parse_version("smietnik") == (0,)


def test_disabled_check_stays_offline(monkeypatch) -> None:
    def boom() -> None:
        raise AssertionError("network touched despite updates.check=false")

    monkeypatch.setattr(updates, "fetch_latest_version", boom)

    assert updates.check(UpdatesConfig(check=False)) is None


def test_daily_throttle_uses_cache(tmp_path, monkeypatch) -> None:
    monkeypatch.setattr(updates, "_cache_file", lambda: tmp_path / "cache.json")
    calls = []
    monkeypatch.setattr(
        updates, "fetch_latest_version", lambda: calls.append(1) or ("v9.9.9", "url")
    )

    first = updates.check(UpdatesConfig(), now=1000.0)
    second = updates.check(UpdatesConfig(), now=2000.0)  # within a day: cached
    third = updates.check(UpdatesConfig(), now=1000.0 + 90000)  # next day

    assert len(calls) == 2
    assert first is not None and first.newer
    assert second is not None and second.latest == "v9.9.9"
    assert third is not None


def test_offline_failure_is_cached_too(tmp_path, monkeypatch) -> None:
    monkeypatch.setattr(updates, "_cache_file", lambda: tmp_path / "cache.json")
    calls = []
    monkeypatch.setattr(updates, "fetch_latest_version", lambda: calls.append(1) or None)

    assert updates.check(UpdatesConfig(), now=1000.0) is None
    assert updates.check(UpdatesConfig(), now=2000.0) is None  # no second request

    assert len(calls) == 1
    cached = json.loads((tmp_path / "cache.json").read_text())
    assert cached["latest"] == ""


def test_config_parses_updates_section() -> None:
    assert parse_config({}).updates.check is True
    assert parse_config({"updates": {"check": False}}).updates.check is False
