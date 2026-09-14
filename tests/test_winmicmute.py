"""Tests for the Windows muter's bookkeeping (no Core Audio, runs anywhere).

Core Audio itself cannot be exercised off Windows — and should not be, since a
test that really mutes the machine's microphone is a test that can be noticed
from the next room. What matters here is the logic around it: who gets muted,
what gets restored, and what happens to an application whose session dies while
voiceflow is holding it down.
"""

from __future__ import annotations

import os
import queue
import threading
import time

import pytest

from voiceflow.config import MuteAppsConfig
from voiceflow.winplat import micmute
from voiceflow.winplat.micmute import WinMicMuter


@pytest.fixture(autouse=True)
def state_file(tmp_path, monkeypatch):
    """Keep the "what do we still owe the user" file out of the real profile.

    The muter reads it in its constructor and writes it after every mute, so
    without this every test would inherit the previous one's leftovers — and
    the developer's own machine would be handed debts invented by a test.
    """
    path = tmp_path / "audio-restore.json"
    monkeypatch.setattr(WinMicMuter, "_state_file", lambda self: path)
    return path


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
    # Park the re-ducking watcher on its first wait: these tests drive the sweep
    # themselves, so its timing must not decide what they see. The one test that
    # is about the thread sets its own interval.
    monkeypatch.setattr(micmute, "_SWEEP_INTERVAL", 3600.0)
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
    """The multiplier applies to the level the app was already playing at."""
    spotify = _Volume(level=0.8)
    world["playback"] = [_session(20, "Spotify.exe", spotify)]
    muter = _muter(MuteAppsConfig(apps=(), duck_to=0.5))

    muter.mute()
    assert spotify.level == 0.4  # 0.8 * 0.5, not a fixed 0.5

    muter.unmute()
    assert spotify.level == 0.8


def test_a_quiet_application_is_ducked_by_the_same_share(world: dict[str, list]) -> None:
    """A quiet app is not exempt — that was the absolute target's failure mode."""
    spotify = _Volume(level=0.2)
    world["playback"] = [_session(20, "Spotify.exe", spotify)]

    _muter(MuteAppsConfig(apps=(), duck_to=0.5)).mute()

    assert spotify.level == 0.1


def test_a_silent_application_is_left_alone(world: dict[str, list]) -> None:
    spotify = _Volume(level=0.0)
    world["playback"] = [_session(20, "Spotify.exe", spotify)]

    _muter(MuteAppsConfig(apps=(), duck_to=0.5)).mute()

    assert spotify.level == 0.0


def test_a_rule_of_one_never_ducks_that_application(world: dict[str, list]) -> None:
    spotify = _Volume(level=0.9)
    world["playback"] = [_session(20, "Spotify.exe", spotify)]
    config = MuteAppsConfig(apps=(), duck_to=0.5, duck_rules=(("Spotify", 1.0),))

    _muter(config).mute()

    assert spotify.level == 0.9


def test_volume_is_restored_on_a_replacement_session(world: dict[str, list]) -> None:
    """The ducked process died; Windows persisted the ducked volume for that app."""
    old = _Volume(level=1.0)
    world["playback"] = [_session(20, "Spotify.exe", old)]
    muter = _muter(MuteAppsConfig(apps=(), duck_to=0.5))
    muter.mute()

    reborn = _Volume(level=0.5)  # started quiet, from the persisted duck
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
    muter = _muter(MuteAppsConfig(apps=(), duck_to=0.5))
    muter.mute()

    world["playback"] = []  # Spotify exited while ducked
    muter.unmute()

    reborn = _Volume(level=0.5)
    world["playback"] = [_session(88, "Spotify.exe", reborn)]
    muter.mute()  # repairs to 1.0, then ducks to 0.5 remembering 1.0
    muter.unmute()

    assert reborn.level == 1.0


def test_a_new_stream_of_a_ducked_application_is_ducked_again(
    world: dict[str, list],
) -> None:
    """The track changes mid-dictation and the next song is born at full volume.

    Windows gives the new stream the application's own level, not the one we
    ducked the old stream to, so a one-shot duck lets the music come back at
    full blast in the middle of a sentence.
    """
    playing = _Volume(level=0.8)
    world["playback"] = [_session(20, "Spotify.exe", playing)]
    muter = _muter(MuteAppsConfig(apps=(), duck_to=0.5))
    muter.mute()
    assert playing.level == 0.4

    next_track = _Volume(level=0.8)  # same process, brand new session
    world["playback"] = [_session(20, "Spotify.exe", next_track)]
    muter._duck()  # noqa: SLF001 - one tick of the watcher

    assert next_track.level == 0.4
    muter.unmute()
    assert next_track.level == 0.8  # the original, not the level it was found at


def test_an_application_that_starts_playing_mid_dictation_is_ducked(
    world: dict[str, list],
) -> None:
    muter = _muter(MuteAppsConfig(apps=(), duck_to=0.5))
    muter.mute()  # nothing is playing yet

    latecomer = _Volume(level=0.6)
    world["playback"] = [_session(20, "Spotify.exe", latecomer)]
    muter._duck()  # noqa: SLF001

    assert latecomer.level == 0.3
    muter.unmute()
    assert latecomer.level == 0.6


def test_a_session_already_at_its_target_is_left_alone(world: dict[str, list]) -> None:
    """Sweeping must not ratchet: ducking a ducked session compounds to silence."""
    spotify = _Volume(level=0.8)
    world["playback"] = [_session(20, "Spotify.exe", spotify)]
    muter = _muter(MuteAppsConfig(apps=(), duck_to=0.5))
    muter.mute()

    for _ in range(5):
        muter._duck()  # noqa: SLF001

    assert spotify.level == 0.4


def test_the_watcher_runs_only_while_a_recording_does(world: dict[str, list]) -> None:
    muter = _muter(MuteAppsConfig(apps=(), duck_to=0.5))

    muter.mute()
    assert muter._watcher is not None  # noqa: SLF001

    muter.unmute()
    assert muter._watcher is None  # noqa: SLF001


def test_the_watcher_re_ducks_on_its_own(
    world: dict[str, list], monkeypatch: pytest.MonkeyPatch
) -> None:
    """The sweep the other tests drive by hand really is driven by the thread."""
    monkeypatch.setattr(micmute, "_SWEEP_INTERVAL", 0.01)
    spotify = _Volume(level=0.8)
    world["playback"] = [_session(20, "Spotify.exe", spotify)]
    muter = _muter(MuteAppsConfig(apps=(), duck_to=0.5))
    muter.mute()

    next_track = _Volume(level=0.8)
    world["playback"] = [_session(20, "Spotify.exe", next_track)]
    deadline = time.monotonic() + 5.0
    while next_track.level == 0.8 and time.monotonic() < deadline:
        time.sleep(0.01)

    assert next_track.level == 0.4
    muter.unmute()


def test_no_watcher_is_left_running_when_ducking_is_off(world: dict[str, list]) -> None:
    muter = _muter(MuteAppsConfig(apps=(), duck_enabled=False))

    muter.mute()

    assert muter._watcher is None  # noqa: SLF001


def test_a_disabled_feature_touches_nothing(world: dict[str, list]) -> None:
    volume = _Volume()
    world["capture"] = [_session(10, "Discord.exe", volume)]

    muter = WinMicMuter(MuteAppsConfig(enabled=False, apps=("Discord.exe",)))
    muter.mute()

    assert muter.available is False
    assert volume.muted is False


def test_two_callers_muting_at_once_leave_one_watcher(world: dict[str, list]) -> None:
    """The hotkey and a room event both mute, on their own threads.

    Unserialised, both could pass the "is a watcher already running?" check
    before either stored its handle. Only one handle is kept, so the other
    thread sweeps on unwatched — ducking the music back down after the restore
    gave it back, for as long as the process lives.
    """
    world["playback"] = [_session(1, "spotify.exe", _Volume(level=1.0))]
    muter = _muter(MuteAppsConfig(apps=("Discord.exe",), duck_to=0.5))
    # Only this test's watchers are ours to judge: an earlier test may still be
    # winding one down, and failing on that would be a flake about somebody
    # else's cleanup.
    before = {t for t in threading.enumerate() if t.name == "voiceflow-duck"}

    failures: list[BaseException] = []

    for _ in range(40):
        barrier = threading.Barrier(2)

        def race() -> None:
            barrier.wait()
            try:
                muter.mute()
            except BaseException as exc:  # noqa: BLE001 - reported below
                failures.append(exc)

        threads = [threading.Thread(target=race) for _ in range(2)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        muter.unmute()

    # Unserialised, the loser of the race joins a handle the winner stored but
    # has not started yet, and mute() raises on the hotkey's thread.
    assert failures == []

    assert muter._watcher is None  # noqa: SLF001
    survivors = {
        t for t in threading.enumerate() if t.name == "voiceflow-duck"
    } - before
    assert survivors == set()


@pytest.mark.skipif(os.name != "nt", reason="wątek Core Audio importuje comtypes")
def test_a_job_whose_caller_gave_up_never_runs() -> None:
    """A sweep that timed out must not execute later.

    It would push volumes back down over a restore that has already put them
    right, and nothing would come along afterwards to fix that.
    """
    thread = micmute._AudioThread()  # noqa: SLF001
    release = threading.Event()
    ran: list[str] = []

    thread._jobs.put(  # noqa: SLF001
        micmute._Job(lambda: release.wait(10), queue.Queue(1))  # noqa: SLF001
    )
    try:
        with pytest.raises(TimeoutError):
            thread.call(lambda: ran.append("late"), timeout=0.2)
        release.set()
        # Long enough that the worker would have reached the abandoned job.
        time.sleep(0.5)
        assert ran == []
    finally:
        release.set()


@pytest.mark.skipif(os.name != "nt", reason="wątek Core Audio importuje comtypes")
def test_a_wedged_audio_service_does_not_grow_the_queue_forever() -> None:
    """Callers are told the service is stuck instead of queueing behind it."""
    thread = micmute._AudioThread()  # noqa: SLF001
    release = threading.Event()

    thread._jobs.put(  # noqa: SLF001
        micmute._Job(lambda: release.wait(10), queue.Queue(1))  # noqa: SLF001
    )
    try:
        for _ in range(micmute._MAX_PENDING_JOBS):  # noqa: SLF001
            with pytest.raises(TimeoutError):
                thread.call(lambda: None, timeout=0.01)
        with pytest.raises(TimeoutError, match="pełna"):
            thread.call(lambda: None, timeout=0.01)
    finally:
        release.set()


def test_a_ducked_volume_outlives_the_daemon_that_ducked_it(
    world: dict[str, list], state_file
) -> None:
    """The number the user is owed cannot live only in a process that crashes.

    This is 18.08 on the developer's machine: Discord went from 100% to 30% and
    the daemon died inside Core Audio 35 seconds later. Windows remembers a
    mixer level per application, so every Discord afterwards was born at 30% —
    and the next dictation ducked that, then restored what it had found.
    """
    volume = _Volume(level=1.0)
    world["playback"] = [_session(10, "Discord.exe", volume)]
    crashing = _muter(MuteAppsConfig(apps=(), duck_enabled=True, duck_to=0.3))

    crashing.mute()
    assert volume.level == pytest.approx(0.3)
    # No unmute(): the process is gone, and with it every pid it knew.
    assert state_file.exists()

    volume.level = 0.3  # what Windows hands the next session of that app
    world["playback"] = [_session(77, "Discord.exe", volume)]
    successor = _muter(MuteAppsConfig(apps=(), duck_enabled=True, duck_to=0.3))
    successor.mute()

    # Repaired to the real original before the new duck measured anything, so
    # the duck is a fraction of 100% and not of somebody else's leftovers.
    assert volume.level == pytest.approx(0.3)
    successor.unmute()
    assert volume.level == pytest.approx(1.0)
    assert not state_file.exists()


def test_nothing_is_owed_once_everything_is_restored(world: dict[str, list], state_file) -> None:
    volume = _Volume(level=1.0)
    world["playback"] = [_session(10, "Discord.exe", volume)]
    muter = _muter(MuteAppsConfig(apps=(), duck_enabled=True, duck_to=0.3))

    muter.mute()
    muter.unmute()

    assert not state_file.exists()


def test_already_quiet_session_is_not_ducked_further(world: dict[str, list]) -> None:
    """Below the floor there is nothing audible to take away — and if the restore
    ever went missing, that value is what Windows would keep for the app."""
    quiet = _Volume(level=0.15)
    world["playback"].append(_session(30, "Spotify.exe", quiet))
    muter = _muter(MuteAppsConfig(apps=(), duck_to=0.6))

    muter.mute()

    assert quiet.level == pytest.approx(0.15)


def test_the_core_audio_thread_collects_its_garbage_before_it_answers(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """pycaw's pointers land in cycles; freed by another thread's collector, a
    COM Release is an access violation. So the Core Audio thread must collect
    them itself, and must do so before the caller gets its reply."""
    import gc
    import sys
    import types

    monkeypatch.setitem(
        sys.modules,
        "comtypes",
        types.SimpleNamespace(COINIT_MULTITHREADED=0, CoInitializeEx=lambda flags: None),
    )
    collected_on: list[str] = []
    real_collect = gc.collect

    def recording_collect(*args, **kwargs):
        collected_on.append(threading.current_thread().name)
        return real_collect(*args, **kwargs)

    monkeypatch.setattr(gc, "collect", recording_collect)

    thread = micmute._AudioThread()  # noqa: SLF001

    assert thread.call(lambda: 42, timeout=5) == 42
    assert collected_on.count("voiceflow-coreaudio") == 1

    def explode() -> None:
        raise RuntimeError("Core Audio is having a day")

    with pytest.raises(RuntimeError):
        thread.call(explode, timeout=5)
    # A failing job leaves the same garbage behind and is collected the same way.
    assert collected_on.count("voiceflow-coreaudio") == 2
