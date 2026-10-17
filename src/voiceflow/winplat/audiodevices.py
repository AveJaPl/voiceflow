"""Mikrofony, które widzi Windows: lista do ustawień i wybór urządzenia do nagrania.

Rejestrator nagrywa przez PortAudio (pakiet sounddevice) na ścieżce MME —
domyślnej na Windowsie i jedynej, która sama przelicza dowolny mikrofon na
16 kHz mono. Lista urządzeń pochodzi stąd prosto z winmm, tej samej warstwy,
którą czyta MME w PortAudio, więc nazwy w ustawieniach są dokładnie tymi, które
rejestrator potem znajdzie. Do tego winmm nie potrzebuje COM-u, a COM w tym
procesie ma już za sobą dwa access violation (patrz ``micmute``).

PortAudio czyta listę urządzeń raz, przy imporcie, i trzyma ją do końca procesu.
Demon żyje tygodniami: zmiana domyślnego mikrofonu w Windowsie albo słuchawki
Bluetooth, które połączyły się po starcie, nie docierały do niego wcale, a numery
urządzeń MME przesuwają się po każdym podłączeniu i odłączeniu — stare numery
potrafią otworzyć nie ten mikrofon. :func:`snapshot` jest tanim zdjęciem tego,
co widzi winmm; rejestrator porównuje je przed każdym nagraniem i odświeża
PortAudio tylko wtedy, gdy coś się zmieniło.

Nazwy MME są ucinane do 31 znaków, a nazwę w ``config.yaml`` mógł też wpisać
człowiek, więc :func:`match_device` wybacza ucięcie i fragment nazwy.
"""

from __future__ import annotations

import ctypes
import logging
from collections.abc import Iterable
from dataclasses import dataclass
from functools import lru_cache

LOGGER = logging.getLogger(__name__)

#: Komunikat waveInMessage zwracający numer urządzenia ustawionego w Windowsie
#: jako domyślne. Tego samego pyta MME w PortAudio, ustalając swoje domyślne.
_DRVM_MAPPER_PREFERRED_GET = 0x2015
#: (UINT)-1 — „mapper”, czyli pseudo-urządzenie, do którego kieruje się
#: komunikaty o urządzeniu domyślnym.
_WAVE_MAPPER = 0xFFFFFFFF
_MMSYSERR_NOERROR = 0
#: Tyle znaków nazwy mieści WAVEINCAPSW; dłuższe nazwy MME są ucinane.
MME_NAME_LIMIT = 31


@dataclass(frozen=True, slots=True)
class DeviceSnapshot:
    """Mikrofony winmm w kolejności ich numerów plus numer domyślnego."""

    names: tuple[str, ...] = ()
    preferred: int | None = None

    @property
    def default_name(self) -> str | None:
        """Nazwa mikrofonu, który Windows ma teraz ustawiony jako domyślny."""
        if self.preferred is None or not 0 <= self.preferred < len(self.names):
            return None
        return self.names[self.preferred]


class _WaveInCaps(ctypes.Structure):
    """WAVEINCAPSW — szPname ma 32 znaki razem z zerem, stąd ucinane nazwy."""

    _fields_ = [
        ("wMid", ctypes.c_ushort),
        ("wPid", ctypes.c_ushort),
        ("vDriverVersion", ctypes.c_uint),
        ("szPname", ctypes.c_wchar * 32),
        ("dwFormats", ctypes.c_ulong),
        ("wChannels", ctypes.c_ushort),
        ("wReserved1", ctypes.c_ushort),
    ]


@lru_cache(maxsize=1)
def _winmm():  # pragma: no cover - Windows runtime path
    # Własna instancja zamiast ctypes.windll.winmm: argtypes ustawione na
    # współdzielonej bibliotece zmieniłyby je każdemu innemu użytkownikowi.
    library = ctypes.WinDLL("winmm")
    library.waveInGetNumDevs.argtypes = []
    library.waveInGetNumDevs.restype = ctypes.c_uint
    library.waveInGetDevCapsW.argtypes = [
        ctypes.c_size_t,
        ctypes.POINTER(_WaveInCaps),
        ctypes.c_uint,
    ]
    library.waveInGetDevCapsW.restype = ctypes.c_uint
    library.waveInMessage.argtypes = [
        ctypes.c_void_p,
        ctypes.c_uint,
        ctypes.POINTER(ctypes.c_ulong),
        ctypes.POINTER(ctypes.c_ulong),
    ]
    library.waveInMessage.restype = ctypes.c_uint
    return library


def snapshot() -> DeviceSnapshot:  # pragma: no cover - Windows runtime path
    """Co winmm widzi teraz. Kilka wywołań bez COM-u, ułamek milisekundy.

    Rzuca ``OSError``, gdy winmm nie odpowiada — wołający decyduje, czy to
    znaczy „nie wiem” (rejestrator), czy błąd do pokazania (okno).
    """
    winmm = _winmm()
    names: list[str] = []
    for device_id in range(winmm.waveInGetNumDevs()):
        caps = _WaveInCaps()
        result = winmm.waveInGetDevCapsW(device_id, ctypes.byref(caps), ctypes.sizeof(caps))
        # Urządzenie, które zniknęło w trakcie wyliczania, zostaje jako puste
        # miejsce: numery muszą się zgadzać z tymi, które zobaczy PortAudio.
        names.append(caps.szPname if result == _MMSYSERR_NOERROR else "")
    device = ctypes.c_ulong()
    flags = ctypes.c_ulong()
    result = winmm.waveInMessage(
        _WAVE_MAPPER, _DRVM_MAPPER_PREFERRED_GET, ctypes.byref(device), ctypes.byref(flags)
    )
    preferred = device.value if result == _MMSYSERR_NOERROR else None
    return DeviceSnapshot(tuple(names), preferred)


def input_device_names(current: DeviceSnapshot) -> list[str]:
    """Nazwy do pokazania w ustawieniach: bez pustych i bez powtórzeń."""
    return list(dict.fromkeys(name for name in current.names if name.strip()))


def match_device(wanted: str, candidates: Iterable[tuple[int, str]]) -> int | None:
    """Numer urządzenia, którego nazwa najlepiej pasuje do ``wanted``.

    Kolejno: ta sama nazwa (bez względu na wielkość liter), nazwa ucięta po
    jednej ze stron — MME tnie do 31 znaków, inne warstwy podają pełną — i na
    końcu fragment nazwy, jak go zwykle wpisuje człowiek. W każdym kroku
    wygrywa pierwsze urządzenie, czyli to o niższym numerze.
    """
    target = wanted.strip().casefold()
    if not target:
        return None
    listed = [(index, name.strip().casefold()) for index, name in candidates]
    listed = [(index, name) for index, name in listed if name]
    for index, name in listed:
        if name == target:
            return index
    # Tylko nazwa długa na cały limit mogła zostać ucięta. Bez tego warunku
    # urządzenie nazwane krótko „Mikrofon” przejęłoby każdy „Mikrofon (…)”.
    for index, name in listed:
        if (len(name) >= MME_NAME_LIMIT and target.startswith(name)) or (
            len(target) >= MME_NAME_LIMIT and name.startswith(target)
        ):
            return index
    for index, name in listed:
        if target in name:
            return index
    return None
