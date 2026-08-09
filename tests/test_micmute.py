"""Tests for muting other applications' capture streams during recording."""

from __future__ import annotations

import json

from voiceflow.config import MuteAppsConfig, parse_config
from voiceflow.micmute import MicMuter, _Target

PW_DUMP = json.dumps(
    [
        {
            "id": 84,
            "type": "PipeWire:Interface:Node",
            "info": {
                "props": {
                    "media.class": "Stream/Input/Audio",
                    "application.name": "WEBRTC VoiceEngine",
                }
            },
        },
        {
            "id": 88,
            "type": "PipeWire:Interface:Node",
            "info": {
                "props": {
                    "media.class": "Stream/Input/Audio",
                    "application.name": "discord_capture",
                }
            },
        },
        {
            "id": 90,
            "type": "PipeWire:Interface:Node",
            "info": {
                "props": {
                    "media.class": "Stream/Output/Audio",
                    "application.name": "WEBRTC VoiceEngine",
                }
            },
        },
        {"id": 5, "type": "PipeWire:Interface:Client"},
    ]
)


class _FakeMuter(MicMuter):
    """MicMuter with subprocess plumbing replaced by an in-memory PipeWire."""

    def __init__(
        self,
        config: MuteAppsConfig,
        *,
        premuted: set[int] | None = None,
        volumes: dict[int, float] | None = None,
    ) -> None:
        super().__init__(config)
        # Pretend the binaries exist regardless of the test machine.
        self._wpctl = "/usr/bin/wpctl"
        self._pw_dump = "/usr/bin/pw-dump"
        self.premuted = premuted or set()
        self.volumes = volumes if volumes is not None else {90: 1.0}
        self.mute_calls: list[tuple[int, bool]] = []
        self.volume_calls: list[tuple[int, float]] = []

    def _find_targets(self, media_class):  # type: ignore[override]
        objects = json.loads(PW_DUMP)
        wanted = {name.casefold() for name in self.config.apps}
        found = []
        for entry in objects:
            if entry.get("type") != "PipeWire:Interface:Node":
                continue
            props = (entry.get("info") or {}).get("props") or {}
            if props.get("media.class") != media_class:
                continue
            app = str(props.get("application.name", ""))
            if app.casefold() in wanted:
                found.append(_Target(int(entry["id"]), app))
        return found

    def _is_muted(self, node_id: int) -> bool:  # type: ignore[override]
        return node_id in self.premuted

    def _set_mute(self, node_id: int, muted: bool) -> bool:  # type: ignore[override]
        self.mute_calls.append((node_id, muted))
        return True

    def _get_volume(self, node_id: int):  # type: ignore[override]
        return self.volumes.get(node_id)

    def _set_volume(self, node_id: int, volume: float) -> bool:  # type: ignore[override]
        self.volume_calls.append((node_id, volume))
        self.volumes[node_id] = volume
        return True


def test_mutes_only_the_configured_capture_stream() -> None:
    muter = _FakeMuter(MuteAppsConfig())

    muter.mute()

    # Node 84 (Discord mic): yes. Node 88 (game capture) and 90 (output): no.
    assert muter.mute_calls == [(84, True)]


def test_unmute_restores_exactly_what_was_muted() -> None:
    muter = _FakeMuter(MuteAppsConfig())
    muter.mute()

    muter.unmute()

    assert muter.mute_calls == [(84, True), (84, False)]
    muter.unmute()
    assert muter.mute_calls == [(84, True), (84, False)]  # idempotent


def test_manually_muted_stream_stays_muted() -> None:
    """The user muted themselves in Discord: that state is theirs to keep."""
    muter = _FakeMuter(MuteAppsConfig(), premuted={84})

    muter.mute()
    muter.unmute()

    assert muter.mute_calls == []


def test_disabled_feature_does_nothing() -> None:
    muter = _FakeMuter(MuteAppsConfig(enabled=False))

    muter.mute()

    assert muter.mute_calls == []


def test_missing_binaries_are_survivable() -> None:
    muter = MicMuter(MuteAppsConfig())
    muter._wpctl = None  # noqa: SLF001

    muter.mute()
    muter.unmute()


def test_leftover_state_is_restored_before_a_new_mute() -> None:
    """A crash between mute and unmute must not strand the previous streams."""
    muter = _FakeMuter(MuteAppsConfig())
    muter.mute()

    muter.mute()

    assert muter.mute_calls == [(84, True), (84, False), (84, True)]


def test_ducks_playback_to_configured_fraction() -> None:
    """Node 90 is Discord's OUTPUT (people talking): duck it, restore it exactly."""
    muter = _FakeMuter(MuteAppsConfig(), volumes={90: 0.85})

    muter.mute()
    assert muter.volume_calls == [(90, 0.4)]

    muter.unmute()
    assert muter.volume_calls == [(90, 0.4), (90, 0.85)]


def test_quieter_stream_is_not_ducked_up() -> None:
    """If Discord already plays at 30%, ducking to 40% would make it LOUDER."""
    muter = _FakeMuter(MuteAppsConfig(duck_volume=0.4), volumes={90: 0.3})

    muter.mute()
    muter.unmute()

    assert muter.volume_calls == []


def test_duck_disabled_leaves_volume_alone() -> None:
    muter = _FakeMuter(MuteAppsConfig(duck_enabled=False), volumes={90: 1.0})

    muter.mute()

    assert muter.volume_calls == []
    assert muter.mute_calls == [(84, True)]


def test_duck_volume_above_one_is_clamped() -> None:
    """A config typo like duck_volume: 40 must not blast the call at 4000%."""
    muter = _FakeMuter(MuteAppsConfig(duck_volume=40.0), volumes={90: 0.85})

    muter.mute()

    assert muter.volume_calls == []  # 0.85 <= 1.0 (clamped), so left alone


def test_config_parses_duck_settings() -> None:
    config = parse_config({"mute_apps": {"duck_enabled": False, "duck_volume": 0.25}})

    assert config.mute_apps.duck_enabled is False
    assert config.mute_apps.duck_volume == 0.25


def test_config_parses_custom_app_list() -> None:
    config = parse_config({"mute_apps": {"enabled": True, "apps": ["TeamSpeak", "Zoom"]}})

    assert config.mute_apps.apps == ("TeamSpeak", "Zoom")


def test_config_defaults_to_discord() -> None:
    config = parse_config({})

    assert config.mute_apps.enabled is True
    assert config.mute_apps.apps == ("WEBRTC VoiceEngine",)
