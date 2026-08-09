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
        {
            "id": 95,
            "type": "PipeWire:Interface:Node",
            "info": {
                "props": {
                    "media.class": "Stream/Output/Audio",
                    "application.name": "Spotify",
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
        self.volumes = volumes if volumes is not None else {90: 1.0, 95: 1.0}
        self.mute_calls: list[tuple[int, bool]] = []
        self.volume_calls: list[tuple[int, float]] = []

        self.dead_nodes: set[int] = set()
        self.pw_objects = json.loads(PW_DUMP)

    def _find_nodes(self, media_class, wanted):  # type: ignore[override]
        objects = self.pw_objects
        found = []
        for entry in objects:
            if entry.get("type") != "PipeWire:Interface:Node":
                continue
            props = (entry.get("info") or {}).get("props") or {}
            if props.get("media.class") != media_class:
                continue
            app = str(props.get("application.name", ""))
            if not app:
                continue
            if wanted is None or app.casefold() in wanted:
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
        if node_id in self.dead_nodes:
            return False
        self.volume_calls.append((node_id, volume))
        self.volumes[node_id] = volume
        return True

    # test helpers ---------------------------------------------------------

    def kill_node(self, node_id: int) -> None:
        """Simulate a stream vanishing (silent call: Discord suspends it)."""
        self.dead_nodes.add(node_id)
        self.pw_objects = [o for o in self.pw_objects if o.get("id") != node_id]

    def spawn_output(self, node_id: int, app: str, volume: float) -> None:
        """Simulate a fresh playback stream of ``app`` appearing."""
        self.pw_objects.append(
            {
                "id": node_id,
                "type": "PipeWire:Interface:Node",
                "info": {
                    "props": {
                        "media.class": "Stream/Output/Audio",
                        "application.name": app,
                    }
                },
            }
        )
        self.volumes[node_id] = volume


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


def test_ducks_every_playing_app_to_the_default() -> None:
    """Discord (90) AND Spotify (95) both play: both duck to the default, both restored."""
    muter = _FakeMuter(MuteAppsConfig(), volumes={90: 0.85, 95: 1.0})

    muter.mute()
    assert sorted(muter.volume_calls) == [(90, 0.4), (95, 0.4)]

    muter.unmute()
    assert sorted(muter.volume_calls[2:]) == [(90, 0.85), (95, 1.0)]


def test_per_app_rules_override_the_default() -> None:
    """Remembered per-app targets: Discord to 30%, Spotify to 20%."""
    config = MuteAppsConfig(duck_rules=(("WEBRTC VoiceEngine", 0.3), ("spotify", 0.2)))
    muter = _FakeMuter(config, volumes={90: 1.0, 95: 1.0})

    muter.mute()

    assert sorted(muter.volume_calls) == [(90, 0.3), (95, 0.2)]


def test_rule_of_one_means_never_duck() -> None:
    config = MuteAppsConfig(duck_rules=(("Spotify", 1.0),))
    muter = _FakeMuter(config, volumes={90: 1.0, 95: 1.0})

    muter.mute()

    assert muter.volume_calls == [(90, 0.4)]


def test_quieter_stream_is_not_ducked_up() -> None:
    """If an app already plays below its target, ducking would make it LOUDER."""
    muter = _FakeMuter(MuteAppsConfig(duck_volume=0.4), volumes={90: 0.3, 95: 0.2})

    muter.mute()
    muter.unmute()

    assert muter.volume_calls == []


def test_duck_disabled_leaves_volume_alone() -> None:
    muter = _FakeMuter(MuteAppsConfig(duck_enabled=False), volumes={90: 1.0, 95: 1.0})

    muter.mute()

    assert muter.volume_calls == []
    assert muter.mute_calls == [(84, True)]


def test_duck_volume_above_one_is_clamped() -> None:
    """A config typo like duck_volume: 40 must not blast the call at 4000%."""
    muter = _FakeMuter(MuteAppsConfig(duck_volume=40.0), volumes={90: 0.85, 95: 0.9})

    muter.mute()

    assert muter.volume_calls == []  # clamped to 1.0 => nothing is louder than that


def test_vanished_stream_is_restored_on_its_replacement_node() -> None:
    """The ducked node died, but the app already has a fresh stream: restore it.

    Without this, WirePlumber persists the ducked volume under the app's name
    and every future stream of that app is born quiet.
    """
    muter = _FakeMuter(MuteAppsConfig(), volumes={90: 1.0, 95: 1.0})
    muter.mute()  # ducks node 90 (Discord) to 0.4

    muter.kill_node(90)
    muter.spawn_output(97, "WEBRTC VoiceEngine", volume=0.4)  # persisted duck
    muter.unmute()

    assert muter.volumes[97] == 1.0


def test_vanished_stream_is_restored_at_the_next_recording() -> None:
    """No stream at unmute time at all: the restore waits for the app's return."""
    muter = _FakeMuter(MuteAppsConfig(), volumes={90: 1.0, 95: 1.0})
    muter.mute()
    muter.kill_node(90)
    muter.unmute()  # nothing to restore onto — parked as pending

    # The call comes back, born quiet from WirePlumber's persisted state.
    muter.spawn_output(97, "WEBRTC VoiceEngine", volume=0.4)
    muter.mute()

    # Fixed to 100% BEFORE ducking, so this duck saved the true original...
    assert (97, 1.0) in muter.volume_calls
    muter.unmute()
    # ...and the second unmute restores it to 100% again.
    assert muter.volumes[97] == 1.0


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


def test_config_parses_duck_rules() -> None:
    config = parse_config({"mute_apps": {"duck_rules": {"Spotify": 0.2, "Discord": 0.3}}})

    assert dict(config.mute_apps.duck_rules) == {"Spotify": 0.2, "Discord": 0.3}
