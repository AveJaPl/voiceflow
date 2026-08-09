"""Mute/duck other applications' audio on Windows via Core Audio (pycaw).

Same interface as the Linux MicMuter (``mute()``/``unmute()``/``available``).
Windows exposes per-session playback volume (ducking works fully) but has no
public per-app *capture* mute, so the mic-mute half is a documented no-op —
Discord still goes quiet for friends because push-to-talk users are muted by
silence detection, but this limitation is stated in docs/WINDOWS.md rather
than hidden. pycaw and comtypes load lazily; missing packages degrade to a
logged warning, never an error.

Two COM rules shape the code below. Every thread that touches Core Audio must
initialise COM itself — and voiceflow calls this from three different threads
(the hotkey thread mutes, the transcription worker restores, shutdown cleans
up). And an interface pointer obtained on one apartment cannot be used from
another, so the original volumes are remembered as plain numbers keyed by
process id, and the sessions are re-resolved when it is time to restore.
"""

from __future__ import annotations

import contextlib
import logging
from collections.abc import Iterator

from voiceflow.config import MuteAppsConfig

LOGGER = logging.getLogger(__name__)


@contextlib.contextmanager
def _com_apartment() -> Iterator[None]:
    """Initialise COM for the calling thread, and undo it afterwards."""
    import comtypes

    initialised = False
    try:
        comtypes.CoInitialize()
        initialised = True
    except OSError as exc:
        # RPC_E_CHANGED_MODE: the thread is already in a different apartment.
        # That is still usable, it just must not be uninitialised here.
        LOGGER.debug("COM było już zainicjalizowane na tym wątku: %s", exc)
    try:
        yield
    finally:
        if initialised:
            with contextlib.suppress(Exception):
                comtypes.CoUninitialize()


class WinMicMuter:
    """Duck playback sessions per application; restore exact volumes after."""

    def __init__(self, config: MuteAppsConfig) -> None:
        self.config = config
        #: process id -> the volume that process had before we touched it.
        self._ducked: dict[int, float] = {}
        self._ready = False
        if config.enabled and config.duck_enabled:
            try:  # lazy, optional
                import comtypes  # noqa: F401
                import pycaw.pycaw  # noqa: F401

                self._ready = True
            except ImportError:
                LOGGER.warning(
                    "Przyciszanie aplikacji wymaga pakietów pycaw i comtypes (uv sync)"
                )

    @property
    def available(self) -> bool:
        return self._ready

    def mute(self) -> None:
        if not self.available:
            return
        if self._ducked:
            self.unmute()
        try:
            self._ducked = self._duck()
        except Exception:
            LOGGER.exception("Przyciszanie nie powiodło się; kontynuuję")

    def unmute(self) -> None:
        if not self._ducked:
            return
        restore, self._ducked = self._ducked, {}
        try:
            self._restore(restore)
        except Exception:
            LOGGER.exception("Nie można przywrócić głośności sesji")

    def _duck(self) -> dict[int, float]:  # pragma: no cover - requires Core Audio
        from pycaw.pycaw import AudioUtilities

        default = min(self.config.duck_volume, 1.0)
        rules = {name.casefold(): value for name, value in self.config.duck_rules}
        ducked: dict[int, float] = {}
        with _com_apartment():
            for session in AudioUtilities.GetAllSessions():
                process = session.Process
                if process is None:
                    continue
                name = process.name()  # e.g. "Spotify.exe"
                bare = name.removesuffix(".exe")
                target = min(rules.get(name.casefold(), rules.get(bare.casefold(), default)), 1.0)
                if target >= 1.0:
                    continue
                volume = session.SimpleAudioVolume
                original = float(volume.GetMasterVolume())
                if original <= target:
                    continue
                volume.SetMasterVolume(target, None)
                ducked[session.ProcessId] = original
                LOGGER.info("Ściszono %s z %.0f%% do %.0f%%", bare, original * 100, target * 100)
        return ducked

    def _restore(self, ducked: dict[int, float]) -> None:  # pragma: no cover - Core Audio
        with _com_apartment():
            from pycaw.pycaw import AudioUtilities

            for session in AudioUtilities.GetAllSessions():
                original = ducked.get(session.ProcessId)
                if original is None:
                    continue
                try:
                    session.SimpleAudioVolume.SetMasterVolume(original, None)
                except Exception:
                    LOGGER.warning("Nie można przywrócić głośności PID %s", session.ProcessId)
