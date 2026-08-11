"""Tests for the Windows muter's bookkeeping (no Core Audio, runs anywhere).

Core Audio itself cannot be exercised off Windows — and should not be, since a
test that really mutes the machine's microphone is a test that can be noticed
from the next room. What matters here is the logic around it: who gets muted,
what gets restored, and what happens to an application whose session dies while
voiceflow is holding it down.
"""

from __future__ import annotations

import pytest

from voiceflow.config import MuteAppsConfig
from voiceflow.winplat import micmute
from voiceflow.winplat.micmute import WinMicMuter


class _Volume:
    """Stand-in for ISimpleAudioVolume, recording what was done to it."""

    def __init__(self, muted: bool = False, level: float = 1.0) -> None:
        self.muted = muted
        self.level = level
        #: Every mute state written, in order — some tests are about sequence.
        self.mute_writes: list[bool] = []

    def GetMute(self) -> bool:  # noqa: N802 - COM naming
        return self.muted

    def SetMute(self, value: int, _guid: object) -> None:  # noqa: N802
        self.muted = bool(value)
        self.mute_writes.append(bool(value))

    def GetMasterVolume(self) -> float:  # noqa: N802
        return self.level

    def SetMasterVolume(self, value: float, _guid: object) -> None:  # noqa: N802
        self.level = value


@pytest.fixture
def world(monkeypatch: pytest.MonkeyPatch) -> dict[str, list]:
    """A fake Core Audio: two lists of sessions the muter can walk."""
    sessions: dict[str, list] = {"capture": [], "playback": []}
    # Call inline instead of hopping to the Core Audio thread; there is no COM
    # here to keep alive, and a test should not depend on a background worker.
    monkeypatch.setattr(micmute, "run_with_audio", lambda function, **_: function())
    monkeypatch.setattr(micmute, "capture_sessions", lambda: iter(list(sessions["capture"])))
    monkeypatch.setattr(micmute, "_playback_sessions", lambda: iter(list(sessions["playback"])))
    return sessions


def _muter(config: MuteAppsConfig) -> WinMicMuter:
    muter = WinMicMuter(config)
    # Pretend pycaw/comtypes imported cleanly, so the suite runs off Windows.
    muter._ready = True  # noqa: SLF001
    return muter


def _session(pid: int, app: str, volume: _Volume) -> object:
    return micmute._Session(pid, app, volume)  # noqa: SLF001


def test_only_the_configured_application_is_muted(world: dict[str, list]) -> None:
    discord, obs = _Volume(), _Volume()
    world["capture"] = [_session(10, "Discord.exe", discord), _session(11, "obs64.exe", obs)]

    _muter(MuteAppsConfig(apps=("Discord.exe",))).mute()

    assert discord.muted is True
    assert obs.muted is False


def test_application_matches_with_or_without_the_exe_suffix(world: dict[str, list]) -> None:
    """Nobody should have to know whether the config wants the extension."""
    volume = _Volume()
    world["capture"] = [_session(10, "Discord.exe", volume)]

    _muter(MuteAppsConfig(apps=("discord",))).mute()

    assert volume.muted is True


def test_a_microphone_the_user_muted_themselves_is_left_alone(world: dict[str, list]) -> None:
    """Muting yourself in Discord is your decision; a dictation must not undo it."""
    volume = _Volume(muted=True)
    world["capture"] = [_session(10, "Discord.exe", volume)]
    muter = _muter(MuteAppsConfig(apps=("Discord.exe",)))

    muter.mute()
    muter.unmute()

    assert volume.muted is True


def test_unmute_restores_the_microphone(world: dict[str, list]) -> None:
    volume = _Volume()
    world["capture"] = [_session(10, "Discord.exe", volume)]
    muter = _muter(MuteAppsConfig(apps=("Discord.exe",)))

    muter.mute()
    muter.unmute()

    assert volume.muted is False


def test_microphone_is_restored_on_the_applications_new_session(world: dict[str, list]) -> None:
    """Discord restarted its capture while muted — Windows remembers per app.

    Following the process id alone would leave the user silent on their next
    call, with the mute flag persisted and nothing on screen to explain it.
    """
    old, new = _Volume(), _Volume(muted=True)
    world["capture"] = [_session(10, "Discord.exe", old)]
    muter = _muter(MuteAppsConfig(apps=("Discord.exe",)))
    muter.mute()

    world["capture"] = [_session(77, "Discord.exe", new)]  # same app, new process
    muter.unmute()

    assert new.muted is False


def test_microphone_left_muted_is_repaired_at_the_next_recording(
    world: dict[str, list],
) -> None:
    """No session at all to restore onto: the repair waits for the app's return."""
    volume = _Volume()
    world["capture"] = [_session(10, "Discord.exe", volume)]
    muter = _muter(MuteAppsConfig(apps=("Discord.exe",)))
    muter.mute()

    world["capture"] = []  # Discord released the microphone entirely
    muter.unmute()

    revived = _Volume(muted=True)  # born muted from Windows' persisted state
    world["capture"] = [_session(77, "Discord.exe", revived)]
    muter.mute()

    # Repaired first, then muted again for the recording that just started —
    # and crucially NOT treated as "the user muted this themselves".
    assert revived.mute_writes == [False, True]
    muter.unmute()
    assert revived.muted is False


def test_playback_is_ducked_and_restored_exactly(world: dict[str, list]) -> None:
    spotify = _Volume(level=0.85)
    world["playback"] = [_session(20, "Spotify.exe", spotify)]
    muter = _muter(MuteAppsConfig(apps=(), duck_volume=0.4))

    muter.mute()
    assert spotify.level == 0.4

    muter.unmute()
    assert spotify.level == 0.85


def test_an_application_quieter_than_the_target_is_left_alone(world: dict[str, list]) -> None:
    spotify = _Volume(level=0.2)
    world["playback"] = [_session(20, "Spotify.exe", spotify)]

    _muter(MuteAppsConfig(apps=(), duck_volume=0.4)).mute()

    assert spotify.level == 0.2


def test_a_rule_of_one_never_ducks_that_application(world: dict[str, list]) -> None:
    spotify = _Volume(level=0.9)
    world["playback"] = [_session(20, "Spotify.exe", spotify)]
    config = MuteAppsConfig(apps=(), duck_volume=0.4, duck_rules=(("Spotify", 1.0),))

    _muter(config).mute()

    assert spotify.level == 0.9


def test_volume_is_restored_on_a_replacement_session(world: dict[str, list]) -> None:
    """The ducked process died; Windows persisted the ducked volume for that app."""
    old = _Volume(level=1.0)
    world["playback"] = [_session(20, "Spotify.exe", old)]
    muter = _muter(MuteAppsConfig(apps=(), duck_volume=0.4))
    muter.mute()

    reborn = _Volume(level=0.4)  # started quiet, from the persisted duck
    world["playback"] = [_session(88, "Spotify.exe", reborn)]
    muter.unmute()

    assert reborn.level == 1.0


def test_a_lost_volume_is_repaired_before_the_next_duck(world: dict[str, list]) -> None:
    """Repair must happen BEFORE ducking, or the duck saves the quiet value.

    Getting this order wrong is how an application ends up permanently silent:
    the ducked volume gets recorded as its "original" and restored forever after.
    """
    original = _Volume(level=1.0)
    world["playback"] = [_session(20, "Spotify.exe", original)]
    muter = _muter(MuteAppsConfig(apps=(), duck_volume=0.4))
    muter.mute()

    world["playback"] = []  # Spotify exited while ducked
    muter.unmute()

    reborn = _Volume(level=0.4)
    world["playback"] = [_session(88, "Spotify.exe", reborn)]
    muter.mute()  # repairs to 1.0, then ducks to 0.4 remembering 1.0
    muter.unmute()

    assert reborn.level == 1.0


def test_a_disabled_feature_touches_nothing(world: dict[str, list]) -> None:
    volume = _Volume()
    world["capture"] = [_session(10, "Discord.exe", volume)]

    muter = WinMicMuter(MuteAppsConfig(enabled=False, apps=("Discord.exe",)))
    muter.mute()

    assert muter.available is False
    assert volume.muted is False
