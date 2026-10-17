"""Microphone recording on Windows via PortAudio (the sounddevice package).

Mirrors the Linux ``Recorder`` interface exactly: ``start() -> Path``,
``stop() -> Path``, ``cancel()``, ``cleanup()`` — the daemon composes it the
same way. Audio is written incrementally as raw 16 kHz mono s16 frames so the
live-preview tail reader works unchanged (it reads PCM past the WAV header).

Mikrofon wybiera ``audio.source``: ``null`` to domyślny mikrofon Windowsa,
nazwa to konkretne urządzenie MME (patrz ``audiodevices``). Przed każdym
nagraniem lista urządzeń PortAudio jest porównywana z tym, co widzi Windows,
bo demon żyje dłużej niż jakikolwiek układ podłączonych mikrofonów.
"""

from __future__ import annotations

import logging
import threading
import uuid
import wave
from collections.abc import Callable
from pathlib import Path

from voiceflow.config import AudioConfig
from voiceflow.winplat import audiodevices

LOGGER = logging.getLogger(__name__)

SAMPLE_RATE = 16000

#: Zdjęcie mikrofonów, z którym PortAudio było ostatnio inicjowane. Na poziomie
#: modułu, bo PortAudio jest jedno na proces, a nie jedno na rejestrator.
_portaudio_devices: audiodevices.DeviceSnapshot | None = None


class RecorderError(RuntimeError):
    """Raised when recording cannot be started or finalized."""


class WinRecorder:
    """One PortAudio input stream at a time, written straight to a WAV file."""

    def __init__(
        self,
        config: AudioConfig,
        runtime_directory: Path,
        on_max_duration: Callable[[], None] | None = None,
        on_notice: Callable[[str], None] | None = None,
    ) -> None:
        self.config = config
        self.runtime_directory = runtime_directory
        self.on_max_duration = on_max_duration
        #: Komunikat dla użytkownika, gdy wybranego mikrofonu nie ma.
        self.on_notice = on_notice
        self._stream = None
        self._wave: wave.Wave_write | None = None
        self._path: Path | None = None
        self._timer: threading.Timer | None = None
        self._lock = threading.Lock()
        #: Czy brak wybranego mikrofonu został już zgłoszony. Jedno powiadomienie
        #: na każde zniknięcie, a nie jedno na każde dyktowanie bez słuchawek.
        self._missing_reported = False

    @property
    def is_recording(self) -> bool:
        with self._lock:
            return self._stream is not None

    def start(self) -> Path:
        try:
            import sounddevice  # lazy: Windows-only dependency
        except ImportError as exc:  # pragma: no cover - dependency environment
            raise RecorderError(
                "Brak pakietu sounddevice — uruchom: uv sync"
            ) from exc
        with self._lock:
            if self._stream is not None:
                raise RecorderError("Nagrywanie już trwa")
            self.runtime_directory.mkdir(parents=True, exist_ok=True)
            path = self.runtime_directory / f"recording-{uuid.uuid4().hex}.wav"
            handle = wave.open(str(path), "wb")
            handle.setnchannels(1)
            handle.setsampwidth(2)
            handle.setframerate(SAMPLE_RATE)

            def callback(indata, _frames, _time, status) -> None:
                if status:
                    LOGGER.debug("PortAudio status: %s", status)
                # Called from PortAudio's realtime thread. writeframesraw, not
                # writeframes: the latter rewrites the RIFF header on every
                # block, and three extra seeks per 20 ms of audio is exactly the
                # kind of stall that shows up as dropped words. close() patches
                # the header once at the end instead.
                #
                # Nothing may propagate out of here either — an exception on
                # PortAudio's thread takes down the stream, not the caller.
                try:
                    handle.writeframesraw(bytes(indata))
                except Exception:  # noqa: BLE001 - closed mid-callback during stop()
                    pass

            # Tutaj, pod blokadą i bez otwartego strumienia — jedyne miejsce,
            # w którym PortAudio wolno zainicjować od nowa.
            try:
                refresh_portaudio(sounddevice)
            except Exception:  # noqa: BLE001 - stara lista jest lepsza niż brak nagrania
                LOGGER.warning("Nie udało się odświeżyć listy mikrofonów", exc_info=True)
            try:
                device = self._input_device(sounddevice)
                stream = sounddevice.RawInputStream(
                    samplerate=SAMPLE_RATE,
                    channels=1,
                    dtype="int16",
                    device=device,
                    callback=callback,
                )
                stream.start()
            except Exception as exc:
                handle.close()
                path.unlink(missing_ok=True)
                raise RecorderError(f"Nie można uruchomić nagrywania: {exc}") from exc
            self._stream = stream
            self._wave = handle
            self._path = path
            self._timer = threading.Timer(self.config.max_seconds, self._limit_reached)
            self._timer.daemon = True
            self._timer.start()
            LOGGER.info(
                "Rozpoczęto nagrywanie do %s (mikrofon: %s)",
                path,
                _device_name(sounddevice, device),
            )
            return path

    def _input_device(self, sounddevice) -> int | None:
        """Numer urządzenia PortAudio z ``audio.source``; None to domyślny Windowsa.

        Wybranego mikrofonu, którego nie ma — słuchawki rozłączone, USB pod
        inną nazwą — nie traktujemy jak błędu: nagrywa domyślny, a użytkownik
        dostaje jedno powiadomienie, że to nie ten mikrofon, który wybrał.
        """
        wanted = (self.config.source or "").strip()
        if not wanted:
            return None
        index = audiodevices.match_device(wanted, _mme_inputs(sounddevice))
        if index is not None:
            self._missing_reported = False
            return index
        LOGGER.warning("Mikrofon %r jest niedostępny; nagrywam z domyślnego", wanted)
        if not self._missing_reported:
            self._missing_reported = True
            if self.on_notice is not None:
                try:
                    self.on_notice(f"Mikrofon „{wanted}” jest niedostępny — nagrywam z domyślnego")
                except Exception:  # noqa: BLE001 - powiadomienie nie zatrzyma nagrania
                    LOGGER.exception("Błąd powiadomienia o niedostępnym mikrofonie")
        return None

    def _limit_reached(self) -> None:
        LOGGER.warning("Osiągnięto limit nagrania: %d s", self.config.max_seconds)
        if self.on_max_duration is not None:
            try:
                self.on_max_duration()
            except Exception:
                LOGGER.exception("Błąd obsługi limitu czasu nagrania")

    def stop(self) -> Path:
        with self._lock:
            stream, handle, path, timer = self._stream, self._wave, self._path, self._timer
            if stream is None or handle is None or path is None:
                raise RecorderError("Nagrywanie nie trwa")
            self._stream = self._wave = self._path = self._timer = None
        if timer is not None:
            timer.cancel()
        try:
            stream.stop()
            stream.close()
        finally:
            handle.close()
        if not path.exists() or path.stat().st_size <= 44:
            path.unlink(missing_ok=True)
            raise RecorderError("Nagranie jest puste")
        return path

    def cancel(self) -> None:
        try:
            path = self.stop()
        except RecorderError as exc:
            LOGGER.warning("Anulowanie nagrania: %s", exc)
            return
        path.unlink(missing_ok=True)

    def cleanup(self) -> None:
        if self.is_recording:
            self.cancel()


def refresh_portaudio(sounddevice) -> None:
    """Zainicjuj PortAudio od nowa, jeśli Windows widzi inne mikrofony niż ono.

    Ponowna inicjalizacja trwa kilkadziesiąt milisekund (wylicza wszystkie
    warstwy audio), więc dzieje się tylko po zmianie: nowym albo odłączonym
    urządzeniu lub innym domyślnym mikrofonie. Wolno ją wołać wyłącznie wtedy,
    gdy żaden strumień nie jest otwarty — terminate urwałby go w pół słowa.
    """
    global _portaudio_devices
    try:
        current = audiodevices.snapshot()
    except OSError as exc:
        LOGGER.debug("winmm nie podał listy mikrofonów: %s", exc)
        return
    if _portaudio_devices is None:
        # Pierwsze nagranie w tym procesie: import sounddevice przed chwilą
        # zainicjował PortAudio, więc jego lista jest świeża.
        _portaudio_devices = current
        return
    if current == _portaudio_devices:
        return
    LOGGER.info("Zmieniły się mikrofony w systemie; odświeżam listę urządzeń PortAudio")
    # Po nieudanej poprzedniej próbie PortAudio może być niezainicjowane,
    # a terminate na niezainicjowanym kończy się błędem.
    if sounddevice._initialized:  # noqa: SLF001 - sounddevice nie ma publicznego odświeżania
        sounddevice._terminate()  # noqa: SLF001
    sounddevice._initialize()  # noqa: SLF001
    _portaudio_devices = current


def _mme_inputs(sounddevice) -> list[tuple[int, str]]:
    """Urządzenia wejściowe ścieżki MME jako (numer PortAudio, nazwa).

    Tylko MME: ten sam mikrofon występuje też w DirectSound, WASAPI i WDM-KS,
    a WASAPI i WDM-KS same nie przeliczają częstotliwości — 16 kHz z mikrofonu
    48 kHz otwiera bez kłopotu tylko MME. Na nim nagrywa też domyślny mikrofon.
    """
    mme = next(
        (
            index
            for index, api in enumerate(sounddevice.query_hostapis())
            if api.get("name") == "MME"
        ),
        None,
    )
    return [
        (index, str(info.get("name", "")))
        for index, info in enumerate(sounddevice.query_devices())
        if info.get("max_input_channels", 0) > 0 and (mme is None or info.get("hostapi") == mme)
    ]


def _device_name(sounddevice, device: int | None) -> str:
    """Nazwa urządzenia do logu — żeby „nie słyszy mnie” dało się sprawdzić."""
    try:
        info = (
            sounddevice.query_devices(kind="input")
            if device is None
            else sounddevice.query_devices(device)
        )
        return str(info.get("name", "?"))
    except Exception:  # noqa: BLE001 - to tylko log
        return "?"
