"""Mute/duck other applications' audio on Windows via Core Audio (pycaw).

Same interface as the Linux MicMuter (``mute()``/``unmute()``/``available``).
Windows exposes per-session playback volume (ducking works fully) but has no
public per-app *capture* mute, so the mic-mute half is a documented no-op —
Discord still goes quiet for friends because push-to-talk users are muted by
silence detection, but this limitation is stated in docs/WINDOWS.md rather
than hidden. pycaw and comtypes load lazily; missing packages degrade to a
logged warning, never an error.
"""

from __future__ import annotations

import logging

from voiceflow.config import MuteAppsConfig

LOGGER = logging.getLogger(__name__)


class WinMicMuter:
    """Duck playback sessions per application; restore exact volumes after."""

    def __init__(self, config: MuteAppsConfig) -> None:
        self.config = config
        self._ducked: list[tuple[object, float]] = []
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
            self._duck()
        except Exception:
            LOGGER.exception("Przyciszanie nie powiodło się; kontynuuję")

    def unmute(self) -> None:
        for volume, original in self._ducked:
            try:
                volume.SetMasterVolume(original, None)  # type: ignore[attr-defined]
            except Exception:
                LOGGER.warning("Nie można przywrócić głośności sesji")
        self._ducked = []

    def _duck(self) -> None:  # pragma: no cover - requires Windows Core Audio
        from pycaw.pycaw import AudioUtilities

        default = min(self.config.duck_volume, 1.0)
        rules = {name.casefold(): value for name, value in self.config.duck_rules}
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
            self._ducked.append((volume, original))
            LOGGER.info("Ściszono %s z %.0f%% do %.0f%%", bare, original * 100, target * 100)
