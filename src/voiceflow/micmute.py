"""Mute and duck other applications' audio while a dictation is recorded.

Voice chats (Discord and friends) keep capturing while the user dictates, so
everyone on the call hears the prompt being spoken. PipeWire exposes each
application's capture as its own ``Stream/Input/Audio`` node, which means the
chat's stream can be muted on its own — the physical microphone stays live for
``pw-record``.

ALL application playback (``Stream/Output/Audio`` — music, calls, videos) is
ducked while recording, because audio in the headphones derails the sentence
being dictated. The configured numbers are **multipliers of each app's current
volume** (``duck_rules`` per app, ``duck_to`` for the rest), so ducking is the
same reduction whether the user listens loud or quiet; 1.0 means "never duck
this one". Original volumes are captured per stream and restored exactly.

One scale trap worth knowing: ``wpctl`` speaks the same cubic curve as the
desktop's volume slider, not raw amplitude. A slider at 0.29 is 0.29³ ≈ 2.4% of
full amplitude, which is why an absolute duck target of "29%" landed on
inaudible rather than quiet.

Node ids change between sessions and even between calls, so targets are resolved
by ``application.name`` at mute time, never cached across recordings.

One trap shaped this module's restore path: a voice chat's playback stream
*disappears mid-recording* whenever the call goes silent (Discord suspends the
node), and WirePlumber persists the last-seen volume **per application name**.
If the ducked value is what gets persisted, every future stream of that app is
born quiet — permanently, surviving reboots. Restoring must therefore never
give up on a dead node id: it falls back to re-resolving the app by name, and
failed restores are remembered and retried when the app's stream reappears.

Those parked restores are written to disk, because the daemon restarting is
exactly as fatal to them as forgetting them would be: measured on a live
system, three dictations whose restore never landed left Chromium persisted at
0.6³ ≈ 22% of its slider, surviving reboots. The same reasoning gives ducking a
floor — an app already this quiet gains nothing from being ducked further, and
has everything to lose if that value is the one WirePlumber remembers.
"""

from __future__ import annotations

import json
import logging
import shutil
import subprocess
import threading
from dataclasses import dataclass
from pathlib import Path

from voiceflow.config import MuteAppsConfig
from voiceflow.paths import pending_restores_file

#: Jak często, w trakcie dyktowania, sprawdzamy czy nie pojawił się nowy
#: strumień do ściszenia. Zmiana utworu w odtwarzaczu potrafi zamknąć jeden
#: strumień i otworzyć drugi — bez tego nowy leciałby na pełnej głośności.
DUCK_RESCAN_SECONDS = 1.0

#: Poniżej tego poziomu nie ściszamy dalej. Ściszanie czegoś, co i tak ledwo
#: słychać, nic nie daje, a gdyby przywrócenie nie doszło do skutku, to właśnie
#: ta wartość zostałaby zapamiętana przez WirePlumbera jako głośność aplikacji.
#: Podłoga jest bezpiecznikiem na wypadek, gdyby zapamiętany oryginał gdzieś
#: przepadł — sama w sobie nie zastępuje przywracania.
DUCK_FLOOR = 0.2

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

    def __init__(self, config: MuteAppsConfig, *, store: Path | None = None) -> None:
        self.config = config
        #: Gdzie trafiają odłożone przywrócenia. Wstrzykiwalne, żeby testy nie
        #: pisały do prawdziwego katalogu danych użytkownika.
        self._store = store
        self._muted: list[_Target] = []
        #: (target, original volume) pairs for playback streams we turned down.
        self._ducked: list[tuple[_Target, float]] = []
        #: Węzły już ściszone -> poziom, do którego je ściszyliśmy. Sam zbiór id
        #: nie wystarczy: Spotify przy zmianie utworu zostawia ten sam węzeł,
        #: ale ustawia mu głośność od nowa — trzeba wiedzieć, dokąd dościszyć.
        #: (Drugiego ściszenia „od zera" nadal nie robimy: zapamiętałoby ściszony
        #: poziom jako oryginalny i zostawiło aplikację cicho na stałe.)
        self._duck_targets: dict[int, float] = {}
        #: Ściszanie działa przez cały czas nagrywania, nie tylko w chwili startu,
        #: więc dogląda go osobny wątek. Blokada chroni listę współdzieloną z nim.
        self._duck_lock = threading.Lock()
        self._duck_stop: threading.Event | None = None
        self._duck_thread: threading.Thread | None = None
        #: app (casefolded) -> (display name, original volume) for restores that
        #: found no live stream; retried whenever the app shows up again.
        #: Wczytywane z dysku, bo poprzedni demon mógł zakończyć się, zanim
        #: zdążył je zastosować.
        self._pending_restores: dict[str, tuple[str, float]] = self._load_pending()
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
        # A stream that vanished before its restore may be back by now — fix it
        # BEFORE ducking, so the duck records the true original volume.
        self._retry_pending_restores()
        for target in self._find_targets("Stream/Input/Audio"):
            if self._is_muted(target.node_id):
                LOGGER.debug("Strumień %s już wyciszony ręcznie; zostawiam", target.app)
                continue
            if self._set_mute(target.node_id, True):
                self._muted.append(target)
                LOGGER.info("Wyciszono mikrofon aplikacji %s (node %d)", target.app, target.node_id)
        if self.config.duck_enabled:
            self._duck()
            self._start_duck_watch()

    def unmute(self) -> None:
        """Restore every stream muted or ducked by :meth:`mute`. Never raises."""
        self._stop_duck_watch()
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
                continue
            # The node died mid-recording (silent call => Discord suspends the
            # stream). WirePlumber has already persisted the DUCKED volume for
            # this app name, so simply forgetting would leave every future
            # stream quiet. Try the app's current streams; else park it.
            if not self._restore_by_app(target.app, original):
                LOGGER.warning(
                    "Strumień %s zniknął przed przywróceniem głośności; "
                    "spróbuję ponownie, gdy się pojawi",
                    target.app,
                )
                self._pending_restores[target.app.casefold()] = (target.app, original)
                self._save_pending()
        self._ducked = []
        self._duck_targets.clear()

    def _restore_by_app(self, app: str, original: float) -> bool:
        """Set ``original`` on every current playback stream of ``app``."""
        restored = False
        for node in self._find_nodes("Stream/Output/Audio", wanted={app.casefold()}):
            if self._set_volume(node.node_id, original):
                LOGGER.info(
                    "Przywrócono głośność %s do %.0f%% (nowy node %d)",
                    app,
                    original * 100,
                    node.node_id,
                )
                restored = True
        return restored

    def _retry_pending_restores(self) -> None:
        """Fix apps whose restore failed because their stream was gone."""
        changed = False
        for key, (app, original) in list(self._pending_restores.items()):
            if self._restore_by_app(app, original):
                del self._pending_restores[key]
                changed = True
        if changed:
            self._save_pending()

    # -- trwały zapis odłożonych przywróceń ---------------------------------

    def _store_path(self) -> Path | None:
        """Where parked restores live, or None if the directory is unusable."""
        if self._store is not None:
            return self._store
        try:
            return pending_restores_file()
        except OSError as exc:
            LOGGER.warning("Brak katalogu na odłożone przywrócenia: %s", exc)
            return None

    def _load_pending(self) -> dict[str, tuple[str, float]]:
        """Read restores a previous daemon run could not apply.

        Anything unreadable is treated as "nothing parked": a corrupt file must
        not stop dictation from starting, and the worst case it costs is one
        application staying quiet until the user raises it by hand.
        """
        path = self._store_path()
        if path is None:
            return {}
        try:
            raw = json.loads(path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            return {}
        except (OSError, ValueError) as exc:
            LOGGER.warning("Nie można odczytać odłożonych przywróceń: %s", exc)
            return {}
        if not isinstance(raw, dict):
            return {}
        parked: dict[str, tuple[str, float]] = {}
        for key, value in raw.items():
            try:
                app = str(value["app"])
                volume = float(value["volume"])
            except (TypeError, KeyError, ValueError):
                continue
            # A garbled number must never be handed to set-volume: restoring to
            # something absurd is worse than leaving the app quiet.
            if app and 0.0 < volume <= 2.0:
                parked[str(key)] = (app, volume)
        if parked:
            LOGGER.info(
                "Wczytano %d odłożonych przywróceń głośności z poprzedniej sesji", len(parked)
            )
        return parked

    def _save_pending(self) -> None:
        """Persist parked restores; write through a temp file so a crash mid-write
        cannot leave a half-written list behind."""
        path = self._store_path()
        if path is None:
            return
        payload = {
            key: {"app": app, "volume": volume}
            for key, (app, volume) in self._pending_restores.items()
        }
        try:
            if not payload:
                path.unlink(missing_ok=True)
                return
            tmp = path.with_name(path.name + ".tmp")
            tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
            tmp.replace(path)
        except OSError as exc:
            LOGGER.warning("Nie można zapisać odłożonych przywróceń: %s", exc)

    def _start_duck_watch(self) -> None:
        """Keep ducking whatever starts playing until the recording ends.

        Ducking once, at the start, only covered streams that already existed.
        Changing a track closes one stream and opens another, and that new one
        came in at full volume straight into the microphone.
        """
        if self._duck_stop is not None:
            return
        stop = threading.Event()
        self._duck_stop = stop
        thread = threading.Thread(target=self._watch_ducking, args=(stop,), daemon=True)
        self._duck_thread = thread
        thread.start()

    def _stop_duck_watch(self) -> None:
        stop, thread = self._duck_stop, self._duck_thread
        self._duck_stop = None
        self._duck_thread = None
        if stop is not None:
            stop.set()
        if thread is not None and thread.is_alive():
            thread.join(timeout=2.0)

    def _watch_ducking(self, stop: threading.Event) -> None:
        while not stop.wait(DUCK_RESCAN_SECONDS):
            try:
                self._duck()
            except Exception:
                # Zepsute doglądanie nie może przewrócić nagrywania.
                LOGGER.warning("Nie udało się dościszyć nowych strumieni", exc_info=True)

    def _duck(self) -> None:
        """Turn every playing app down to a fraction of where its own slider is.

        Relative, not absolute. An absolute target sounds like a different
        effect depending on how loud the user was already listening: the same
        value is a light dip at full volume and complete silence for someone
        playing music quietly in the background. A multiplier is the same
        reduction either way, which is what "duck" is supposed to mean.
        """
        # Clamp: a multiplier above 1.0 would make audio LOUDER while dictating.
        default = min(self.config.duck_to, 1.0)
        rules = {name.casefold(): volume for name, volume in self.config.duck_rules}
        with self._duck_lock:
            self._duck_streams(default, rules)

    def _duck_streams(self, default: float, rules: dict[str, float]) -> None:
        for target in self._find_playback_streams():
            if target.node_id in self._duck_targets:
                self._reduck_if_raised(target)
                continue
            factor = min(rules.get(target.app.casefold(), default), 1.0)
            if factor >= 1.0:
                # An explicit "never duck this app" rule.
                continue
            original = self._get_volume(target.node_id)
            if original is None or original <= 0.0:
                # Unreadable, or already silent and nothing to take away.
                continue
            if original <= DUCK_FLOOR:
                # Already barely audible. Taking more away is inaudible anyway,
                # and if this restore is the one that goes missing, this is the
                # value the app is stuck with from now on.
                LOGGER.debug(
                    "%s gra już na %.0f%%; nie ściszam poniżej podłogi %.0f%%",
                    target.app,
                    original * 100,
                    DUCK_FLOOR * 100,
                )
                continue
            duck_to = round(original * factor, 2)
            if duck_to >= original:
                # Rounding swallowed the whole reduction; nothing to do.
                continue
            if self._set_volume(target.node_id, duck_to):
                self._ducked.append((target, original))
                self._duck_targets[target.node_id] = duck_to
                LOGGER.info(
                    "Ściszono %s z %.0f%% do %.0f%% (mnożnik %.2f, node %d)",
                    target.app,
                    original * 100,
                    duck_to * 100,
                    factor,
                    target.node_id,
                )

    def _reduck_if_raised(self, target: _Target) -> None:
        """Push a stream back down if its app raised the volume on its own.

        Spotify does exactly that on every track change: same node, volume set
        anew (measured live: our 0.10 was back at 0.41 within a second). The
        original volume stays the one from the first duck — the app was only
        restoring its idea of that same level, not choosing a new one.
        """
        duck_to = self._duck_targets[target.node_id]
        current = self._get_volume(target.node_id)
        if current is None or current <= duck_to + 0.01:
            return
        if self._set_volume(target.node_id, duck_to):
            LOGGER.info(
                "Aplikacja %s podniosła sobie głośność do %.0f%%; ściszam z powrotem "
                "do %.0f%% (node %d)",
                target.app,
                current * 100,
                duck_to * 100,
                target.node_id,
            )

    def _find_playback_streams(self) -> list[_Target]:
        """Every application playback stream — ducking is not limited to the
        mic-mute list, because any audio distracts, not just the voice chat."""
        return self._find_nodes("Stream/Output/Audio", wanted=None)

    # -- plumbing ----------------------------------------------------------

    def _find_targets(self, media_class: str) -> list[_Target]:
        """Streams of the configured (mic-mute) apps only."""
        return self._find_nodes(media_class, wanted={n.casefold() for n in self.config.apps})

    def _find_nodes(self, media_class: str, wanted: set[str] | None) -> list[_Target]:
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
        targets: list[_Target] = []
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
