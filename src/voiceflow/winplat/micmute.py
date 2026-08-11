"""Mute and duck other applications' audio on Windows via Core Audio (pycaw).

Same interface as the Linux MicMuter (``mute()``/``unmute()``/``available``),
and now the same two halves of behaviour:

* the capture sessions of the configured applications are muted, so the voice
  chat stops hearing the prompt while the physical microphone stays live for the
  recorder;
* all application playback is ducked, because audio in the headphones derails
  the sentence being dictated.

Windows does expose per-application capture. Every application recording through
WASAPI owns a session on the capture endpoint with its own mute flag — Discord
appears there for as long as it holds the microphone. An earlier version of this
module declared that impossible and shipped the mic half as a no-op; it is not.
The real limitation is narrower: applications recording through the legacy
MME/DirectSound paths are proxied by the audio service and cannot be singled
out, so they are invisible here.

Two COM rules shape the code. Every thread that touches Core Audio must
initialise COM itself — and voiceflow calls this from three different threads
(the hotkey thread mutes, the transcription worker restores, shutdown cleans
up); see :func:`_com_apartment` for why those apartments are never closed
again. And an interface pointer obtained on one apartment cannot be used from
another, so nothing is cached between calls: state is kept as plain numbers and
names keyed by process id, and sessions are re-resolved at restore time. That is
also why the methods below iterate the session generators and act inline rather
than building the obvious ``{s.pid: s for s in capture_sessions()}`` lookup
table — enumerating twice is cheap, and a machine with more than a handful of
audio sessions does not exist.

One trap shaped the restore path, the same one the Linux module carries.
Windows persists an application's mixer state *per application*, so if a session
dies while we hold it ducked or muted, the ducked volume is what Windows
remembers — and every future session of that app is born quiet, or worse, born
muted. Restoring therefore never gives up on a dead process id: it falls back to
any live session of the same executable, and whatever still cannot be reached is
parked and retried the next time we mute.
"""

from __future__ import annotations

import logging
import queue
import threading
from collections.abc import Callable, Iterator
from dataclasses import dataclass

from voiceflow.config import MuteAppsConfig

LOGGER = logging.getLogger(__name__)

#: EDataFlow.eCapture, and the device-state mask for "plugged in and enabled".
_E_CAPTURE = 1
_DEVICE_ACTIVE = 1


class _AudioThread:
    """The one thread in the process allowed to talk to Core Audio.

    A COM pointer is valid only inside the apartment that created it, and an
    apartment dies with its thread. voiceflow calls in from whichever thread is
    handy — the hotkey thread mutes, a transcription worker restores, shutdown
    cleans up — and pycaw leaves objects behind that only the cyclic collector
    frees, so those pointers routinely outlive the call that made them. When the
    creating thread is gone by then, Release faults: an access violation raised
    inside the garbage collector, at whatever unrelated line happened to
    allocate. Nothing in the traceback points at audio.

    Funnelling every Core Audio call through one immortal daemon thread makes a
    late Release harmless, because its apartment is still standing. The thread
    is a daemon and is never joined, so interpreter shutdown freezes it rather
    than tearing the apartment down under objects that still exist.
    """

    def __init__(self) -> None:
        self._jobs: queue.Queue = queue.Queue()
        threading.Thread(
            target=self._run, name="voiceflow-coreaudio", daemon=True
        ).start()

    def _run(self) -> None:
        import comtypes

        try:
            # Multi-threaded, not the CoInitialize() default. In a
            # single-threaded apartment a pointer may only be released by the
            # thread that made it — and pycaw's session objects land in
            # reference cycles, so they are freed by the cyclic collector on
            # whatever thread happens to run it. That cross-apartment Release
            # is an access violation, raised inside the collector, unrelated to
            # anything in the traceback. Objects in the MTA can be released
            # from any thread, which makes late collection harmless.
            comtypes.CoInitializeEx(comtypes.COINIT_MULTITHREADED)
        except OSError as exc:
            LOGGER.warning("Nie można wejść w apartament MTA: %s", exc)
        while True:
            function, reply = self._jobs.get()
            try:
                reply.put((True, function()))
            except BaseException as exc:  # noqa: BLE001 - handed to the caller
                reply.put((False, exc))

    def call(self, function: Callable[[], object], timeout: float) -> object:
        reply: queue.Queue = queue.Queue(1)
        self._jobs.put((function, reply))
        try:
            succeeded, value = reply.get(timeout=timeout)
        except queue.Empty:
            raise TimeoutError("Core Audio nie odpowiedziało w czasie") from None
        if not succeeded:
            raise value  # type: ignore[misc]
        return value


_AUDIO_THREAD: _AudioThread | None = None
_AUDIO_LOCK = threading.Lock()
#: Core Audio calls are local and quick; anything slower is a wedged service.
_CALL_TIMEOUT = 10.0


def run_with_audio(function: Callable[[], object], timeout: float = _CALL_TIMEOUT) -> object:
    """Run ``function`` on the Core Audio thread and hand back its result."""
    global _AUDIO_THREAD
    with _AUDIO_LOCK:
        if _AUDIO_THREAD is None:
            _AUDIO_THREAD = _AudioThread()
        thread = _AUDIO_THREAD
    return thread.call(function, timeout)


@dataclass(slots=True)
class _Session:
    """One application's audio session, valid only inside its apartment."""

    pid: int
    #: Executable name as Windows reports it, e.g. ``Discord.exe``.
    app: str
    volume: object  # ISimpleAudioVolume
    #: AudioSessionState: 1 is Active, anything else idle or expired. Windows
    #: keeps a session listed after the application lets the device go, so this
    #: is the difference between "is recording" and "recorded at some point".
    active: bool = False


def _process_name(pid: int) -> str | None:
    import psutil

    try:
        return psutil.Process(pid).name()
    except Exception:  # noqa: BLE001 - the process may have exited mid-enumeration
        return None


def capture_sessions() -> Iterator[_Session]:
    """Every application currently holding a microphone, one session each.

    Sessions are spread across capture endpoints — a headset and a webcam are
    separate devices — so every active one is walked, not just the default.
    """
    from comtypes import CLSCTX_ALL, POINTER, cast
    from pycaw.api.audiopolicy import IAudioSessionControl2
    from pycaw.pycaw import AudioUtilities, IAudioSessionManager2, ISimpleAudioVolume

    enumerator = AudioUtilities.GetDeviceEnumerator()
    devices = enumerator.EnumAudioEndpoints(_E_CAPTURE, _DEVICE_ACTIVE)
    for index in range(devices.GetCount()):
        device = devices.Item(index)
        try:
            manager = cast(
                device.Activate(IAudioSessionManager2._iid_, CLSCTX_ALL, None),
                POINTER(IAudioSessionManager2),
            )
            sessions = manager.GetSessionEnumerator()
        except Exception as exc:  # noqa: BLE001 - a device may refuse activation
            LOGGER.debug("Nie można odczytać sesji urządzenia wejściowego: %s", exc)
            continue
        for position in range(sessions.GetCount()):
            control = sessions.GetSession(position)
            try:
                pid = control.QueryInterface(IAudioSessionControl2).GetProcessId()
            except Exception:  # noqa: BLE001
                continue
            # Process id 0 is the shared system session: no application behind
            # it, and muting it would silence the endpoint for everyone.
            if not pid:
                continue
            name = _process_name(pid)
            if name is None:
                continue
            # Muting is deliberately not limited to active sessions: the flag
            # sticks, so an application that picks the microphone back up
            # mid-dictation is already silenced when it does.
            yield _Session(
                pid,
                name,
                control.QueryInterface(ISimpleAudioVolume),
                active=control.GetState() == 1,
            )


def _playback_sessions() -> Iterator[_Session]:
    from pycaw.pycaw import AudioUtilities

    for session in AudioUtilities.GetAllSessions():
        process = session.Process
        if process is None:
            continue
        try:
            name = process.name()
        except Exception:  # noqa: BLE001 - it may have just exited
            continue
        if name:
            yield _Session(session.ProcessId, name, session.SimpleAudioVolume)


def _forms(name: str) -> set[str]:
    """An executable under both the names a user might write it with."""
    folded = name.casefold()
    return {folded, folded.removesuffix(".exe")}


class WinMicMuter:
    """Mute the configured apps' microphones and duck playback, then undo it."""

    def __init__(self, config: MuteAppsConfig) -> None:
        self.config = config
        #: process id -> executable, for capture sessions muted by us. Only what
        #: we muted is unmuted later: a user who muted themselves in Discord by
        #: hand owns that state and it must survive a dictation.
        self._muted: dict[int, str] = {}
        #: process id -> (executable, volume it had before we ducked it).
        self._ducked: dict[int, tuple[str, float]] = {}
        #: Apps whose restore found no live session, retried on the next mute.
        self._pending_unmutes: dict[str, str] = {}
        self._pending_restores: dict[str, tuple[str, float]] = {}
        self._ready = False
        if config.enabled:
            try:  # lazy, optional
                import comtypes  # noqa: F401
                import psutil  # noqa: F401
                import pycaw.pycaw  # noqa: F401

                self._ready = True
            except ImportError:
                LOGGER.warning(
                    "Wyciszanie aplikacji wymaga pakietów pycaw, comtypes i psutil (uv sync)"
                )

    @property
    def available(self) -> bool:
        return self._ready

    def mute(self) -> None:
        """Mute configured microphones and duck playback for one recording."""
        if not self.available:
            return
        if self._muted or self._ducked:
            # A leftover entry means a previous unmute never ran; better to
            # restore those sessions now than to lose track of them entirely.
            LOGGER.warning("Lista wyciszonych nie była pusta; przywracam poprzednie")
            self.unmute()
        try:
            run_with_audio(self._mute_now)
        except Exception:
            LOGGER.exception("Wyciszanie nie powiodło się; kontynuuję nagrywanie")

    def _mute_now(self) -> None:
        # An app that vanished before its restore may be back by now. Fix it
        # BEFORE ducking, so the duck records the true original volume.
        self._retry_pending()
        self._mute_capture()
        if self.config.duck_enabled:
            self._duck()

    def unmute(self) -> None:
        """Restore everything :meth:`mute` touched. Never raises."""
        if not self._muted and not self._ducked:
            return
        muted, self._muted = self._muted, {}
        ducked, self._ducked = self._ducked, {}
        try:
            run_with_audio(lambda: self._unmute_now(muted, ducked))
        except Exception:
            LOGGER.exception("Nie można przywrócić stanu audio")

    def _unmute_now(self, muted: dict[int, str], ducked: dict[int, tuple[str, float]]) -> None:
        self._unmute_capture(muted)
        self._restore(ducked)

    # -- microphones ---------------------------------------------------------

    def _mute_capture(self) -> None:
        wanted: set[str] = set()
        for name in self.config.apps:
            wanted |= _forms(name)
        if not wanted:
            return
        for session in capture_sessions():
            if not _forms(session.app) & wanted:
                continue
            if session.volume.GetMute():
                LOGGER.debug("Mikrofon %s już wyciszony ręcznie; zostawiam", session.app)
                continue
            session.volume.SetMute(1, None)
            self._muted[session.pid] = session.app
            LOGGER.info("Wyciszono mikrofon aplikacji %s (pid %d)", session.app, session.pid)

    def _unmute_capture(self, muted: dict[int, str]) -> None:
        if not muted:
            return
        restored: set[int] = set()
        for session in capture_sessions():
            app = muted.get(session.pid)
            if app is None:
                continue
            session.volume.SetMute(0, None)
            restored.add(session.pid)
            LOGGER.info("Przywrócono mikrofon aplikacji %s (pid %d)", app, session.pid)
        for pid, app in muted.items():
            if pid in restored:
                continue
            # The app stopped capturing while we held it muted. Windows
            # remembers that mute per application, so letting go here would
            # leave the user silent on their next call with no way to tell why.
            if not self._unmute_by_app(app):
                LOGGER.warning(
                    "Sesja mikrofonu %s zniknęła przed przywróceniem; "
                    "spróbuję ponownie, gdy aplikacja znów zacznie nagrywać",
                    app,
                )
                self._pending_unmutes[app.casefold()] = app

    @staticmethod
    def _unmute_by_app(app: str) -> bool:
        """Unmute any live capture session belonging to ``app``."""
        forms = _forms(app)
        restored = False
        for session in capture_sessions():
            if _forms(session.app) & forms and session.volume.GetMute():
                session.volume.SetMute(0, None)
                LOGGER.info("Przywrócono mikrofon %s (nowa sesja, pid %d)", app, session.pid)
                restored = True
        return restored

    # -- playback ------------------------------------------------------------

    def _duck(self) -> None:
        """Turn each session down to a fraction of its own level.

        The configured numbers multiply the app's current volume rather than
        naming a target, matching the Linux backend. An absolute target is a
        different effect depending on how loud the user already was: a light
        dip at full volume, silence for someone playing music quietly.
        """
        # Clamp: a multiplier above 1.0 would make audio LOUDER while dictating.
        default = min(self.config.duck_to, 1.0)
        rules = {name.casefold(): value for name, value in self.config.duck_rules}
        for session in _playback_sessions():
            factor = default
            for form in _forms(session.app):
                if form in rules:
                    factor = rules[form]
                    break
            factor = min(factor, 1.0)
            if factor >= 1.0:
                # An explicit "never duck this app" rule.
                continue
            original = float(session.volume.GetMasterVolume())
            if original <= 0.0:
                # Already silent; nothing to take away and nothing to restore.
                continue
            target = round(original * factor, 2)
            if target >= original:
                # Rounding swallowed the whole reduction.
                continue
            session.volume.SetMasterVolume(target, None)
            self._ducked[session.pid] = (session.app, original)
            LOGGER.info(
                "Ściszono %s z %.0f%% do %.0f%% (mnożnik %.2f)",
                session.app,
                original * 100,
                target * 100,
                factor,
            )

    def _restore(self, ducked: dict[int, tuple[str, float]]) -> None:
        if not ducked:
            return
        restored: set[int] = set()
        for session in _playback_sessions():
            entry = ducked.get(session.pid)
            if entry is None:
                continue
            app, original = entry
            session.volume.SetMasterVolume(original, None)
            restored.add(session.pid)
            LOGGER.info("Przywrócono głośność %s do %.0f%%", app, original * 100)
        for pid, (app, original) in ducked.items():
            if pid in restored:
                continue
            if not self._restore_by_app(app, original):
                LOGGER.warning(
                    "Sesja %s zniknęła przed przywróceniem głośności; "
                    "spróbuję ponownie, gdy się pojawi",
                    app,
                )
                self._pending_restores[app.casefold()] = (app, original)

    @staticmethod
    def _restore_by_app(app: str, original: float) -> bool:
        """Give ``original`` back to any live playback session of ``app``."""
        forms = _forms(app)
        restored = False
        for session in _playback_sessions():
            if _forms(session.app) & forms:
                session.volume.SetMasterVolume(original, None)
                LOGGER.info(
                    "Przywrócono głośność %s do %.0f%% (nowa sesja, pid %d)",
                    app,
                    original * 100,
                    session.pid,
                )
                restored = True
        return restored

    # -- deferred repairs ----------------------------------------------------

    def _retry_pending(self) -> None:
        """Fix apps whose restore failed because their session had gone."""
        for key, app in list(self._pending_unmutes.items()):
            if self._unmute_by_app(app):
                del self._pending_unmutes[key]
        for key, (app, original) in list(self._pending_restores.items()):
            if self._restore_by_app(app, original):
                del self._pending_restores[key]
