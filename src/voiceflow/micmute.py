"""Mute and duck other applications' audio while a dictation is recorded.

Voice chats (Discord and friends) keep capturing while the user dictates, so
everyone on the call hears the prompt being spoken. PipeWire exposes each
application's capture as its own ``Stream/Input/Audio`` node, which means the
chat's stream can be muted on its own — the physical microphone stays live for
``pw-record``.

The same apps' PLAYBACK (``Stream/Output/Audio`` — other people talking) is
ducked to a configured fraction while recording, because a conversation in the
headphones derails the sentence being dictated. Original volumes are captured
per stream and restored exactly.

Node ids change between sessions and even between calls, so targets are resolved
by ``application.name`` at mute time, never cached across recordings.
"""

from __future__ import annotations

import json
import logging
import shutil
import subprocess
from dataclasses import dataclass

from voiceflow.config import MuteAppsConfig

LOGGER = logging.getLogger(__name__)

_TIMEOUT = 3.0


@dataclass(frozen=True, slots=True)
class _Target:
    node_id: int
    app: str


class MicMuter:
    """Mute configured capture streams for the duration of one recording.

    Only streams this class muted get unmuted afterwards: if the user muted
    themselves in Discord by hand, that state is theirs and must survive.
    """

    def __init__(self, config: MuteAppsConfig) -> None:
        self.config = config
        self._muted: list[_Target] = []
        #: (target, original volume) pairs for playback streams we turned down.
        self._ducked: list[tuple[_Target, float]] = []
        self._wpctl = shutil.which("wpctl")
        self._pw_dump = shutil.which("pw-dump")
        if config.enabled and (self._wpctl is None or self._pw_dump is None):
            LOGGER.warning(
                "Wyciszanie aplikacji wymaga wpctl i pw-dump; funkcja będzie pominięta"
            )

    @property
    def available(self) -> bool:
        """Return whether the feature can run at all."""
        return self.config.enabled and self._wpctl is not None and self._pw_dump is not None

    def mute(self) -> None:
        """Mute capture and duck playback for every configured app."""
        if not self.available:
            return
        if self._muted or self._ducked:
            # A leftover list means a previous unmute never ran; better to restore
            # those streams now than to lose track of them entirely.
            LOGGER.warning("Lista wyciszonych nie była pusta; przywracam poprzednie")
            self.unmute()
        for target in self._find_targets("Stream/Input/Audio"):
            if self._is_muted(target.node_id):
                LOGGER.debug("Strumień %s już wyciszony ręcznie; zostawiam", target.app)
                continue
            if self._set_mute(target.node_id, True):
                self._muted.append(target)
                LOGGER.info("Wyciszono mikrofon aplikacji %s (node %d)", target.app, target.node_id)
        if self.config.duck_enabled:
            self._duck()

    def unmute(self) -> None:
        """Restore every stream muted or ducked by :meth:`mute`. Never raises."""
        for target in self._muted:
            if self._set_mute(target.node_id, False):
                LOGGER.info(
                    "Przywrócono mikrofon aplikacji %s (node %d)", target.app, target.node_id
                )
        self._muted = []
        for target, original in self._ducked:
            if self._set_volume(target.node_id, original):
                LOGGER.info(
                    "Przywrócono głośność %s do %.0f%% (node %d)",
                    target.app,
                    original * 100,
                    target.node_id,
                )
        self._ducked = []

    def _duck(self) -> None:
        """Turn the configured apps' playback down to ``duck_volume``."""
        # Clamp: values above 1.0 would make the call LOUDER while dictating.
        duck_to = min(self.config.duck_volume, 1.0)
        for target in self._find_targets("Stream/Output/Audio"):
            original = self._get_volume(target.node_id)
            if original is None or original <= duck_to:
                # Already quieter than the duck target; leave it alone.
                continue
            if self._set_volume(target.node_id, duck_to):
                self._ducked.append((target, original))
                LOGGER.info(
                    "Ściszono %s z %.0f%% do %.0f%% (node %d)",
                    target.app,
                    original * 100,
                    duck_to * 100,
                    target.node_id,
                )

    # -- plumbing ----------------------------------------------------------

    def _find_targets(self, media_class: str) -> list[_Target]:
        try:
            result = subprocess.run(
                [str(self._pw_dump)],
                capture_output=True,
                timeout=_TIMEOUT,
                check=True,
                shell=False,
            )
            objects = json.loads(result.stdout)
        except (OSError, subprocess.SubprocessError, json.JSONDecodeError) as exc:
            LOGGER.warning("Nie można odczytać strumieni PipeWire: %s", exc)
            return []
        wanted = {name.casefold() for name in self.config.apps}
        targets: list[_Target] = []
        for entry in objects:
            if entry.get("type") != "PipeWire:Interface:Node":
                continue
            props = (entry.get("info") or {}).get("props") or {}
            if props.get("media.class") != media_class:
                continue
            app = str(props.get("application.name", ""))
            if app.casefold() in wanted:
                targets.append(_Target(int(entry["id"]), app))
        return targets

    def _get_volume(self, node_id: int) -> float | None:
        """Return the stream volume as a fraction, or None if unreadable."""
        try:
            result = subprocess.run(
                [str(self._wpctl), "get-volume", str(node_id)],
                capture_output=True,
                timeout=_TIMEOUT,
                check=True,
                shell=False,
            )
            # wpctl prints e.g. "Volume: 0.85" or "Volume: 1.00 [MUTED]".
            return float(result.stdout.split()[1])
        except (OSError, subprocess.SubprocessError, IndexError, ValueError) as exc:
            LOGGER.debug("Nie można odczytać głośności node %d: %s", node_id, exc)
            return None

    def _set_volume(self, node_id: int, volume: float) -> bool:
        try:
            subprocess.run(
                [str(self._wpctl), "set-volume", str(node_id), f"{volume:.2f}"],
                capture_output=True,
                timeout=_TIMEOUT,
                check=True,
                shell=False,
            )
            return True
        except (OSError, subprocess.SubprocessError) as exc:
            LOGGER.warning("Nie można ustawić głośności node %d: %s", node_id, exc)
            return False

    def _is_muted(self, node_id: int) -> bool:
        try:
            result = subprocess.run(
                [str(self._wpctl), "get-volume", str(node_id)],
                capture_output=True,
                timeout=_TIMEOUT,
                check=True,
                shell=False,
            )
        except (OSError, subprocess.SubprocessError):
            return False
        return b"MUTED" in result.stdout

    def _set_mute(self, node_id: int, muted: bool) -> bool:
        try:
            subprocess.run(
                [str(self._wpctl), "set-mute", str(node_id), "1" if muted else "0"],
                capture_output=True,
                timeout=_TIMEOUT,
                check=True,
                shell=False,
            )
            return True
        except (OSError, subprocess.SubprocessError) as exc:
            # The stream may have vanished mid-recording (user left the call).
            LOGGER.warning("Nie można przełączyć wyciszenia node %d: %s", node_id, exc)
            return False
