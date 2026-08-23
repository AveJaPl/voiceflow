"""Tests for the daily update check (no network involved)."""

from __future__ import annotations

import json
import urllib.request
from contextlib import contextmanager

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


RELEASES = [
    {"tag_name": "mac-v0.6.0", "html_url": "u/mac-v0.6.0"},
    {"tag_name": "mac-v0.5.2", "html_url": "u/mac-v0.5.2"},
    {"tag_name": "v0.5.0", "html_url": "u/v0.5.0"},
    {"tag_name": "v0.4.0", "html_url": "u/v0.4.0"},
]


def _serve(monkeypatch, payload: object) -> None:
    """Answer the one GET this module makes, without touching the network."""

    @contextmanager
    def fake_urlopen(request, timeout=None):  # noqa: ANN001, ARG001
        class _Response:
            @staticmethod
            def read() -> bytes:
                return json.dumps(payload).encode("utf-8")

        yield _Response()

    monkeypatch.setattr(urllib.request, "urlopen", fake_urlopen)


def test_tag_belongs_to_the_platform_that_can_install_it() -> None:
    assert updates.tag_matches_platform("v0.5.0", "")
    assert updates.tag_matches_platform("0.5.0", "")
    assert not updates.tag_matches_platform("mac-v0.6.0", "")
    assert updates.tag_matches_platform("mac-v0.6.0", "mac-")
    assert not updates.tag_matches_platform("v0.5.0", "mac-")
    assert updates.strip_prefix("mac-v0.6.0", "mac-") == "v0.6.0"
    assert updates.strip_prefix("v0.5.0", "") == "v0.5.0"


def test_mac_build_is_not_an_update_for_everyone_else(monkeypatch) -> None:
    """Wydanie macowe opublikowane po źródłowym ogłaszało się Linuxowi jako 0.6.0
    nad 0.5.0 — aktualizacja, której nie ma i której nie da się zainstalować."""
    _serve(monkeypatch, RELEASES)
    monkeypatch.setattr(updates, "release_prefix", lambda: "")

    assert updates.fetch_latest_version() == ("v0.5.0", "u/v0.5.0")


def test_macos_gets_its_own_packaged_build(monkeypatch) -> None:
    _serve(monkeypatch, RELEASES)
    monkeypatch.setattr(updates, "release_prefix", lambda: "mac-")

    assert updates.fetch_latest_version() == ("v0.6.0", "u/mac-v0.6.0")


def test_no_release_for_this_platform_is_silence(monkeypatch) -> None:
    """Lepiej milczeć niż ogłaszać aktualizację, której użytkownik nie zainstaluje."""
    _serve(monkeypatch, [r for r in RELEASES if r["tag_name"].startswith("mac-")])
    monkeypatch.setattr(updates, "release_prefix", lambda: "")

    assert updates.fetch_latest_version() is None


def test_drafts_and_prereleases_are_skipped(monkeypatch) -> None:
    _serve(
        monkeypatch,
        [{"tag_name": "v9.9.9", "html_url": "u/v9.9.9", "prerelease": True}, *RELEASES],
    )
    monkeypatch.setattr(updates, "release_prefix", lambda: "")

    assert updates.fetch_latest_version() == ("v0.5.0", "u/v0.5.0")


def test_cache_left_by_the_old_check_is_not_trusted(tmp_path, monkeypatch) -> None:
    """Poprzednia wersja modułu zapisywała do cache wydanie obcej platformy;
    uznanie go za odpowiedź powtarzałoby fałszywy komunikat przez całą dobę."""
    cache = tmp_path / "cache.json"
    cache.write_text(
        json.dumps({"checked_at": 1000.0, "latest": "mac-v0.6.0", "url": "u"}),
        encoding="utf-8",
    )
    monkeypatch.setattr(updates, "_cache_file", lambda: cache)
    monkeypatch.setattr(updates, "release_prefix", lambda: "")

    assert updates.check(UpdatesConfig(), now=1100.0) is None

