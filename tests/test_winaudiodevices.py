"""Wybór mikrofonu na Windowsie: dopasowanie nazw i odświeżanie PortAudio.

Ani winmm, ani PortAudio nie są tu prawdziwe — zdjęcie urządzeń i moduł
sounddevice są podstawione, więc suita przechodzi także na Linuksie.
"""

from __future__ import annotations

import sys
import types
from pathlib import Path
from typing import Any

import pytest

from voiceflow.config import AudioConfig
from voiceflow.winplat import audiodevices, recorder
from voiceflow.winplat.audiodevices import DeviceSnapshot, input_device_names, match_device
from voiceflow.winplat.recorder import WinRecorder, refresh_portaudio

HEADSET = "Zestaw słuchawkowy (WH-CH720N)"
BROADCAST = "Mikrofon (NVIDIA Broadcast)"


# -- dopasowanie nazw ----------------------------------------------------------


def test_the_same_name_matches_regardless_of_case() -> None:
    assert match_device("zestaw SŁUCHAWKOWY (wh-ch720n)", [(1, BROADCAST), (2, HEADSET)]) == 2


def test_a_name_mme_cut_short_still_finds_its_device() -> None:
    """MME tnie nazwy do 31 znaków; pełna nazwa z konfiguracji ma i tak trafić."""
    full = "Mikrofon (2- USB PnP Sound Device)"
    truncated = full[: audiodevices.MME_NAME_LIMIT]
    assert match_device(full, [(1, BROADCAST), (4, truncated)]) == 4
    assert match_device(truncated, [(1, BROADCAST), (4, full)]) == 4


def test_a_fragment_typed_by_hand_is_enough() -> None:
    assert match_device("WH-CH720N", [(1, BROADCAST), (2, HEADSET)]) == 2


def test_a_short_device_name_does_not_swallow_a_longer_one() -> None:
    """Krótki „Mikrofon” nie jest uciętą nazwą — nie może przejąć wyboru."""
    assert match_device("Mikrofon (USB)", [(0, "Mikrofon"), (1, HEADSET)]) is None


def test_no_name_and_no_match_mean_no_device() -> None:
    assert match_device("", [(1, BROADCAST)]) is None
    assert match_device("Rode NT-USB", [(1, BROADCAST), (2, HEADSET)]) is None


def test_the_default_name_comes_from_the_preferred_number() -> None:
    assert DeviceSnapshot((BROADCAST, HEADSET), 1).default_name == HEADSET
    assert DeviceSnapshot((BROADCAST,), None).default_name is None
    assert DeviceSnapshot((BROADCAST,), 5).default_name is None


def test_the_settings_list_skips_blanks_and_repeats() -> None:
    snapshot = DeviceSnapshot((BROADCAST, "", HEADSET, BROADCAST), 0)
    assert input_device_names(snapshot) == [BROADCAST, HEADSET]


# -- PortAudio -----------------------------------------------------------------


class _FakeStream:
    def __init__(self, owner: "_FakeSounddevice", **kwargs: Any) -> None:
        owner.opened.append(kwargs["device"])

    def start(self) -> None:
        pass

    def stop(self) -> None:
        pass

    def close(self) -> None:
        pass


class _FakeSounddevice(types.ModuleType):
    """Tyle sounddevice, ile używa rejestrator: MME i WASAPI z tymi samymi mikrofonami."""

    def __init__(self, inputs: list[str]) -> None:
        super().__init__("sounddevice")
        self._initialized = 1
        self.terminated = 0
        self.initialized = 0
        self.opened: list[int | None] = []
        # WASAPI najpierw: dopasowanie ma wybrać MME, choć stoi dalej na liście.
        self.devices = [{"name": name, "hostapi": 1, "max_input_channels": 1} for name in inputs]
        self.devices.append({"name": "Głośniki", "hostapi": 0, "max_input_channels": 0})
        self.devices += [{"name": name, "hostapi": 0, "max_input_channels": 2} for name in inputs]
        self.RawInputStream = lambda **kwargs: _FakeStream(self, **kwargs)

    def _terminate(self) -> None:
        self.terminated += 1
        self._initialized -= 1

    def _initialize(self) -> None:
        self.initialized += 1
        self._initialized += 1

    def query_hostapis(self) -> list[dict[str, Any]]:
        return [{"name": "MME"}, {"name": "Windows WASAPI"}]

    def query_devices(self, device: int | None = None, kind: str | None = None):
        if device is None and kind is None:
            return self.devices
        if device is None:
            return {"name": "domyślny"}
        return self.devices[device]


@pytest.fixture
def snapshots(monkeypatch):
    """Kolejne zdjęcia winmm; PortAudio jeszcze żadnego nie widziało."""
    queue: list[DeviceSnapshot] = []
    monkeypatch.setattr(recorder, "_portaudio_devices", None)
    monkeypatch.setattr(audiodevices, "snapshot", lambda: queue.pop(0) if len(queue) > 1 else queue[0])
    return queue


def test_portaudio_is_left_alone_while_nothing_changes(snapshots) -> None:
    sounddevice = _FakeSounddevice([BROADCAST])
    snapshots.append(DeviceSnapshot((BROADCAST,), 0))
    refresh_portaudio(sounddevice)
    refresh_portaudio(sounddevice)
    assert (sounddevice.terminated, sounddevice.initialized) == (0, 0)


def test_a_new_microphone_or_a_new_default_reinitialises_portaudio(snapshots) -> None:
    sounddevice = _FakeSounddevice([BROADCAST])
    snapshots.extend(
        [
            DeviceSnapshot((BROADCAST,), 0),
            DeviceSnapshot((BROADCAST, HEADSET), 0),  # słuchawki się połączyły
            DeviceSnapshot((BROADCAST, HEADSET), 1),  # i zostały domyślnym
        ]
    )
    refresh_portaudio(sounddevice)
    refresh_portaudio(sounddevice)
    assert (sounddevice.terminated, sounddevice.initialized) == (1, 1)
    refresh_portaudio(sounddevice)
    assert (sounddevice.terminated, sounddevice.initialized) == (2, 2)


def test_an_uninitialised_portaudio_is_only_initialised(snapshots) -> None:
    """Po nieudanej próbie terminate na niezainicjowanym byłby kolejnym błędem."""
    sounddevice = _FakeSounddevice([BROADCAST])
    snapshots.extend([DeviceSnapshot((BROADCAST,), 0), DeviceSnapshot((HEADSET,), 0)])
    refresh_portaudio(sounddevice)
    sounddevice._initialized = 0
    refresh_portaudio(sounddevice)
    assert (sounddevice.terminated, sounddevice.initialized) == (0, 1)


def test_winmm_failing_leaves_portaudio_as_it_is(monkeypatch) -> None:
    sounddevice = _FakeSounddevice([BROADCAST])
    monkeypatch.setattr(recorder, "_portaudio_devices", DeviceSnapshot((BROADCAST,), 0))

    def broken() -> DeviceSnapshot:
        raise OSError("winmm")

    monkeypatch.setattr(audiodevices, "snapshot", broken)
    refresh_portaudio(sounddevice)
    assert (sounddevice.terminated, sounddevice.initialized) == (0, 0)


# -- rejestrator -----------------------------------------------------------------


@pytest.fixture
def fake_sounddevice(monkeypatch, snapshots):
    sounddevice = _FakeSounddevice([BROADCAST, HEADSET])
    snapshots.append(DeviceSnapshot((BROADCAST, HEADSET), 0))
    monkeypatch.setitem(sys.modules, "sounddevice", sounddevice)
    return sounddevice


def _record_once(winrecorder: WinRecorder) -> None:
    winrecorder.start()
    winrecorder.cancel()


def test_no_source_records_from_the_windows_default(fake_sounddevice, tmp_path: Path) -> None:
    _record_once(WinRecorder(AudioConfig(source=None), tmp_path))
    assert fake_sounddevice.opened == [None]


def test_the_chosen_microphone_is_opened_through_mme(fake_sounddevice, tmp_path: Path) -> None:
    _record_once(WinRecorder(AudioConfig(source=HEADSET), tmp_path))
    mme_headset = next(
        index
        for index, info in enumerate(fake_sounddevice.devices)
        if info["name"] == HEADSET and info["hostapi"] == 0
    )
    assert fake_sounddevice.opened == [mme_headset]


def test_a_missing_microphone_falls_back_and_says_so_once(
    fake_sounddevice, tmp_path: Path
) -> None:
    notices: list[str] = []
    winrecorder = WinRecorder(AudioConfig(source="Rode NT-USB"), tmp_path, on_notice=notices.append)
    _record_once(winrecorder)
    _record_once(winrecorder)
    assert fake_sounddevice.opened == [None, None]
    assert len(notices) == 1, "jedno powiadomienie na zniknięcie, nie na każde dyktowanie"
    assert "Rode NT-USB" in notices[0]

    fake_sounddevice.devices.append({"name": "Rode NT-USB", "hostapi": 0, "max_input_channels": 1})
    _record_once(winrecorder)
    fake_sounddevice.devices.pop()
    _record_once(winrecorder)
    assert len(notices) == 2, "ponowne zniknięcie po powrocie znów jest zgłaszane"
