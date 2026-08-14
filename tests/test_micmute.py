"""Tests for muting other applications' capture streams during recording."""

from __future__ import annotations

import json
import logging
import os

import pytest

from voiceflow.config import DEFAULT_MUTE_APPS, MuteAppsConfig, parse_config
from voiceflow.micmute import MicMuter, _Target


def _linux_config(**overrides: object) -> MuteAppsConfig:
    """A config naming the app the fake PipeWire dump below serves.

    The dataclass default is platform-dependent — Core Audio names sessions by
    executable, PipeWire by ``application.name`` — and everything in this file
    exercises the PipeWire backend, so the name is pinned rather than inherited.
    """
    return MuteAppsConfig(apps=("WEBRTC VoiceEngine",), **overrides)  # type: ignore[arg-type]


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
    muter = _FakeMuter(_linux_config())

    muter.mute()

    # Node 84 (Discord mic): yes. Node 88 (game capture) and 90 (output): no.
    assert muter.mute_calls == [(84, True)]


def test_unmute_restores_exactly_what_was_muted() -> None:
    muter = _FakeMuter(_linux_config())
    muter.mute()

    muter.unmute()

    assert muter.mute_calls == [(84, True), (84, False)]
    muter.unmute()
    assert muter.mute_calls == [(84, True), (84, False)]  # idempotent


def test_manually_muted_stream_stays_muted() -> None:
    """The user muted themselves in Discord: that state is theirs to keep."""
    muter = _FakeMuter(_linux_config(), premuted={84})

    muter.mute()
    muter.unmute()

    assert muter.mute_calls == []


def test_disabled_feature_does_nothing() -> None:
    muter = _FakeMuter(_linux_config(enabled=False))

    muter.mute()

    assert muter.mute_calls == []


def test_missing_binaries_are_survivable() -> None:
    muter = MicMuter(_linux_config())
    muter._wpctl = None  # noqa: SLF001

    muter.mute()
    muter.unmute()


def test_leftover_state_is_restored_before_a_new_mute() -> None:
    """A crash between mute and unmute must not strand the previous streams."""
    muter = _FakeMuter(_linux_config())
    muter.mute()

    muter.mute()

    assert muter.mute_calls == [(84, True), (84, False), (84, True)]


def test_ducks_every_playing_app_by_the_default_multiplier() -> None:
    """Both apps drop to the same SHARE of their own level, not to one level.

    The two streams start at different volumes on purpose: an absolute target
    would flatten them together, which is exactly the bug this replaced.
    """
    muter = _FakeMuter(_linux_config(duck_to=0.6), volumes={90: 0.85, 95: 1.0})

    muter.mute()
    assert sorted(muter.volume_calls) == [(90, 0.51), (95, 0.6)]

    muter.unmute()
    assert sorted(muter.volume_calls[2:]) == [(90, 0.85), (95, 1.0)]


def test_per_app_rules_override_the_default() -> None:
    """Per-app multipliers: Discord keeps 30% of its level, Spotify 20%."""
    config = _linux_config(duck_rules=(("WEBRTC VoiceEngine", 0.3), ("spotify", 0.2)))
    muter = _FakeMuter(config, volumes={90: 1.0, 95: 1.0})

    muter.mute()

    assert sorted(muter.volume_calls) == [(90, 0.3), (95, 0.2)]


def test_the_same_rule_ducks_quiet_and_loud_apps_alike() -> None:
    """The point of a multiplier: identical reduction at any listening level.

    Under the old absolute target, 0.5 barely touched an app at full volume and
    silenced one already playing at 0.4.
    """
    config = _linux_config(duck_rules=(("WEBRTC VoiceEngine", 0.5), ("spotify", 0.5)))
    muter = _FakeMuter(config, volumes={90: 1.0, 95: 0.4})

    muter.mute()

    assert sorted(muter.volume_calls) == [(90, 0.5), (95, 0.2)]


def test_rule_of_one_means_never_duck() -> None:
    config = _linux_config(duck_rules=(("Spotify", 1.0),))
    muter = _FakeMuter(config, volumes={90: 1.0, 95: 1.0})

    muter.mute()

    assert muter.volume_calls == [(90, 0.6)]


def test_already_silent_stream_is_left_alone() -> None:
    """Nothing to take away from silence, and no state worth remembering."""
    muter = _FakeMuter(_linux_config(duck_to=0.6), volumes={90: 0.0, 95: 0.0})

    muter.mute()
    muter.unmute()

    assert muter.volume_calls == []


def test_duck_disabled_leaves_volume_alone() -> None:
    muter = _FakeMuter(_linux_config(duck_enabled=False), volumes={90: 1.0, 95: 1.0})

    muter.mute()

    assert muter.volume_calls == []
    assert muter.mute_calls == [(84, True)]


def test_duck_multiplier_above_one_is_clamped() -> None:
    """A config typo like duck_to: 40 must not blast the call at 4000%."""
    muter = _FakeMuter(_linux_config(duck_to=40.0), volumes={90: 0.85, 95: 0.9})

    muter.mute()

    assert muter.volume_calls == []  # clamped to 1.0 => nothing is louder than that


def test_vanished_stream_is_restored_on_its_replacement_node() -> None:
    """The ducked node died, but the app already has a fresh stream: restore it.

    Without this, WirePlumber persists the ducked volume under the app's name
    and every future stream of that app is born quiet.
    """
    muter = _FakeMuter(_linux_config(), volumes={90: 1.0, 95: 1.0})
    muter.mute()  # ducks node 90 (Discord) to 0.4

    muter.kill_node(90)
    muter.spawn_output(97, "WEBRTC VoiceEngine", volume=0.4)  # persisted duck
    muter.unmute()

    assert muter.volumes[97] == 1.0


def test_vanished_stream_is_restored_at_the_next_recording() -> None:
    """No stream at unmute time at all: the restore waits for the app's return."""
    muter = _FakeMuter(_linux_config(), volumes={90: 1.0, 95: 1.0})
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
    config = parse_config({"mute_apps": {"duck_enabled": False, "duck_to": 0.25}})

    assert config.mute_apps.duck_enabled is False
    assert config.mute_apps.duck_to == 0.25


def test_renamed_duck_volume_is_ignored_and_announced(
    caplog: pytest.LogCaptureFixture,
) -> None:
    """Silently reinterpreting the old key would change ducking with no warning."""
    with caplog.at_level(logging.WARNING):
        config = parse_config({"mute_apps": {"duck_volume": 0.29}})

    assert config.mute_apps.duck_to == 0.6
    assert "duck_to" in caplog.text


def test_config_parses_custom_app_list() -> None:
    config = parse_config({"mute_apps": {"enabled": True, "apps": ["TeamSpeak", "Zoom"]}})

    assert config.mute_apps.apps == ("TeamSpeak", "Zoom")


def test_config_defaults_to_discord() -> None:
    """Out of the box Discord's microphone is the one that gets silenced.

    Which name that is depends on who is asking: PipeWire knows the stream as
    "WEBRTC VoiceEngine", Core Audio knows the process as Discord.exe.
    """
    config = parse_config({})

    assert config.mute_apps.enabled is True
    assert config.mute_apps.apps == DEFAULT_MUTE_APPS
    assert DEFAULT_MUTE_APPS == (("Discord.exe",) if os.name == "nt" else ("WEBRTC VoiceEngine",))


def test_config_parses_duck_rules() -> None:
    config = parse_config({"mute_apps": {"duck_rules": {"Spotify": 0.2, "Discord": 0.3}}})

    assert dict(config.mute_apps.duck_rules) == {"Spotify": 0.2, "Discord": 0.3}


# --- ściszanie musi obejmować też to, co zaczyna grać W TRAKCIE -------------


def test_track_started_during_recording_is_ducked_too() -> None:
    """Zmiana utworu zamyka jeden strumień i otwiera drugi.

    Ściszenie wykonywane raz, na starcie, obejmowało tylko strumienie już
    istniejące — nowy utwór wchodził na pełnej głośności prosto w mikrofon.
    """
    muter = _FakeMuter(_linux_config(duck_to=0.5), volumes={90: 1.0, 95: 1.0})
    muter.mute()

    muter.kill_node(90)                                   # koniec utworu
    muter.spawn_output(101, "Spotify", volume=0.8)        # następny rusza
    muter._duck()                                         # tik wątku doglądającego  # noqa: SLF001

    assert muter.volumes[101] == 0.4, "nowy strumień gra dalej na pełnej głośności"


def test_new_stream_is_restored_to_its_own_original_volume() -> None:
    muter = _FakeMuter(_linux_config(duck_to=0.5), volumes={90: 1.0, 95: 1.0})
    muter.mute()
    muter.spawn_output(101, "Spotify", volume=0.8)
    muter._duck()  # noqa: SLF001

    muter.unmute()

    assert muter.volumes[101] == 0.8, "przywrócono nie ten poziom, który zastaliśmy"


def test_app_resetting_its_own_volume_mid_recording_is_ducked_again() -> None:
    """Spotify przy zmianie utworu zostawia TEN SAM węzeł, ale sam ustawia mu
    głośność od nowa (zmierzono na żywo: 0.10 wróciło do 0.41 w niecałą
    sekundę). Strażnik pomijający węzły „już ściszone" nigdy tego nie cofał."""
    muter = _FakeMuter(_linux_config(duck_to=0.5), volumes={90: 1.0, 95: 1.0})
    muter.mute()
    assert muter.volumes[90] == 0.5

    muter.volumes[90] = 1.0  # aplikacja sama przywraca głośność przy nowym utworze
    muter._duck()  # tik wątku doglądającego  # noqa: SLF001

    assert muter.volumes[90] == 0.5, "strumień gra dalej na pełnej głośności"


def test_reducked_stream_still_restores_to_the_first_original() -> None:
    muter = _FakeMuter(_linux_config(duck_to=0.5), volumes={90: 0.8, 95: 1.0})
    muter.mute()
    muter.volumes[90] = 0.8
    muter._duck()  # noqa: SLF001

    muter.unmute()

    assert muter.volumes[90] == 0.8, "podwójne ściszenie zgubiło oryginalny poziom"


def test_repeated_ticks_do_not_compound_the_ducking() -> None:
    """Drugie ściszenie tego samego strumienia zapamiętałoby ściszony poziom
    jako oryginalny i zostawiło aplikację cicho na stałe."""
    muter = _FakeMuter(_linux_config(duck_to=0.5), volumes={90: 1.0, 95: 1.0})
    muter.mute()

    for _ in range(5):
        muter._duck()  # noqa: SLF001
    muter.unmute()

    assert muter.volumes[90] == 1.0
    assert muter.volumes[95] == 1.0


def test_watcher_stops_when_recording_ends() -> None:
    muter = _FakeMuter(_linux_config(duck_to=0.5), volumes={90: 1.0, 95: 1.0})
    muter.mute()
    assert muter._duck_thread is not None and muter._duck_thread.is_alive()  # noqa: SLF001

    muter.unmute()

    assert muter._duck_thread is None  # noqa: SLF001
