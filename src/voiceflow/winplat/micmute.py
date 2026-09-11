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
initialise COM itself, and voiceflow calls in from whichever thread is handy —
the hotkey thread mutes, the transcription worker restores, a room event does
either, shutdown cleans up. Rather than initialise each of them, every call is
funnelled onto one immortal thread; :class:`_AudioThread` explains why that
thread must live in the multi-threaded apartment, and what goes wrong when it
silently does not. And an interface pointer obtained on one apartment cannot be
used from another, so nothing is cached between calls: state is kept as plain
numbers and names keyed by process id, and sessions are re-resolved at restore
time. That is
also why the methods below iterate the session generators and act inline rather
than building the obvious ``{s.pid: s for s in capture_sessions()}`` lookup
table — enumerating twice is cheap, and a machine with more than a handful of
audio sessions does not exist.

Ducking is not a single pass over the sessions that happened to exist when the
hotkey was pressed. A session is born loud: when Spotify moves to the next
track, or a video starts mid-sentence, Windows hands that stream the
application's own volume, not the one we ducked it to — so the music comes back
at full blast in the middle of a dictation. A watcher thread therefore re-walks
the sessions every :data:`_SWEEP_INTERVAL` while the recording runs, pushing
anything that came back up back down and ducking applications that started
playing since. It also means a volume the user raises by hand mid-dictation is
pushed down again, which is the right trade for a few seconds of speech.

One trap shaped the restore path, the same one the Linux module carries.
Windows persists an application's mixer state *per application*, so if a session
dies while we hold it ducked or muted, the ducked volume is what Windows
remembers — and every future session of that app is born quiet, or worse, born
muted. Restoring therefore never gives up on a dead process id: it falls back to
any live session of the same executable, and whatever still cannot be reached is
parked and retried the next time we mute.
"""

from __future__ import annotations

import json
import logging
import queue
import sys
import threading
from collections.abc import Callable, Iterator
from dataclasses import dataclass, field
from pathlib import Path

from voiceflow.config import MuteAppsConfig

LOGGER = logging.getLogger(__name__)

#: EDataFlow.eCapture, and the device-state mask for "plugged in and enabled".
_E_CAPTURE = 1
_DEVICE_ACTIVE = 1

#: How often the ducked applications are re-checked while a recording runs.
#: Enumerating sessions is a handful of local COM calls, and half a second of
#: full-volume music at a track change reads as a glitch rather than as the
#: feature being broken.
_SWEEP_INTERVAL = 0.5
#: How far above its target a session may sit before the sweep pushes it back.
#: Master volume is a float32 round-trip, so an exact comparison would fight
#: the last bit of every value we ourselves wrote.
_DUCK_TOLERANCE = 0.01
#: Below this level nothing is ducked further. Inaudible either way, and if the
#: restore ever goes missing, this is the value Windows keeps for the app.
DUCK_FLOOR = 0.2


@dataclass(slots=True)
class _Job:
    """One piece of Core Audio work and the mailbox for its answer."""

    function: Callable[[], object]
    reply: queue.Queue
    #: Set when the caller stopped waiting. The thread checks this before it
    #: starts a job, because a job that outlived its caller is stale by
    #: definition: a sweep that timed out would, if it ran later, push volumes
    #: back down over a restore that has already put them right.
    abandoned: threading.Event = field(default_factory=threading.Event)


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
        # Bounded. An unbounded queue in front of a wedged audio service grows
        # for as long as the sweep keeps firing, and every entry pins the
        # closure it carries; the cap turns that slow leak into an error the
        # caller can log and skip.
        self._jobs: queue.Queue = queue.Queue(maxsize=_MAX_PENDING_JOBS)
        #: Set by the thread itself when it could not claim the MTA. Read from
        #: other threads, but only ever written once and before any job runs.
        self._broken = False
        threading.Thread(
            target=self._run, name="voiceflow-coreaudio", daemon=True
        ).start()

    def _run(self) -> None:
        # BEFORE the import, and that order is the whole point. comtypes calls
        # CoInitializeEx() on the importing thread as a side effect of being
        # imported, using sys.coinit_flags — which defaults to
        # COINIT_APARTMENTTHREADED. When this thread is the first in the process
        # to import comtypes (the settings window is, because nothing else there
        # touches Core Audio), that side effect puts the thread in an STA, and
        # the CoInitializeEx below then fails with RPC_E_CHANGED_MODE: an
        # apartment cannot be changed once set. The old code logged that failure
        # and carried on inside an STA — the exact arrangement this class exists
        # to avoid, and one that both deadlocks (an STA owes COM a message pump,
        # and this thread never pumps) and faults when the cyclic collector
        # releases a pointer from another thread.
        sys.coinit_flags = 0  # COINIT_MULTITHREADED
        import comtypes
        import gc

        try:
            # Belt and braces: if comtypes was already imported elsewhere, the
            # flag above came too late to matter, but this thread is still
            # uninitialised and this call is what puts it in the MTA. In a
            # single-threaded apartment a pointer may only be released by the
            # thread that made it — and pycaw's session objects land in
            # reference cycles, so they are freed by the cyclic collector on
            # whatever thread happens to run it.
            comtypes.CoInitializeEx(comtypes.COINIT_MULTITHREADED)
        except OSError as exc:
            # Not a warning to shrug at: every call from here on is running in
            # the apartment this class was built to escape. Refuse the work
            # rather than hand back sessions that crash the process later.
            LOGGER.error(
                "Nie można wejść w apartament MTA (%s); wyciszanie aplikacji wyłączone", exc
            )
            self._broken = True
        while True:
            job = self._jobs.get()
            if job.abandoned.is_set():
                continue
            if self._broken:
                job.reply.put((False, RuntimeError("Core Audio bez apartamentu MTA")))
                continue
            try:
                result = (True, job.function())
            except BaseException as exc:  # noqa: BLE001 - handed to the caller
                result = (False, exc)
            # pycaw returns Core Audio pointers that land in reference cycles
            # only the cyclic collector frees — and freeing a COM pointer from
            # any thread but the MTA one that made it is an access violation
            # raised deep inside the collector, on whatever unrelated thread it
            # ran on (an onnxruntime import, a transcription worker, the overlay
            # starting up). The job's own frame is gone now, so those pointers
            # are unreachable; collect them here, on this thread, before handing
            # the reply back. This thread holds the GIL unbroken from the job's
            # return to this call, so no other thread's collector can reach them
            # first. The Release then always runs in the apartment that owns it.
            gc.collect()
            job.reply.put(result)

    def call(self, function: Callable[[], object], timeout: float) -> object:
        job = _Job(function, queue.Queue(1))
        try:
            self._jobs.put_nowait(job)
        except queue.Full:
            raise TimeoutError(
                "Kolejka Core Audio jest pełna; usługa audio nie odpowiada"
            ) from None
        try:
            succeeded, value = job.reply.get(timeout=timeout)
        except queue.Empty:
            # Nobody is listening any more, so make sure the job never runs.
            # It may already be executing, which cannot be undone — but every
            # job still waiting behind it is now known to be stale.
            job.abandoned.set()
            raise TimeoutError("Core Audio nie odpowiedziało w czasie") from None
        if not succeeded:
            raise value  # type: ignore[misc]
        return value


_AUDIO_THREAD: _AudioThread | None = None
_AUDIO_LOCK = threading.Lock()
#: Core Audio calls are local and quick; anything slower is a wedged service.
#: This is the budget for restoring, where being thorough beats being prompt —
#: whatever is not put back stays wrong until the next dictation.
_CALL_TIMEOUT = 10.0
#: The budget for muting, which the daemon runs while holding the lock that
#: also answers "are you alive?". Ten seconds there reads to the watchdog as a
#: wedged process and gets voiceflow killed mid-sentence; silencing the voice
#: chat is best effort, so it gives up quickly and the dictation goes ahead.
_MUTE_TIMEOUT = 1.5
#: The budget for one sweep. Sweeps repeat twice a second, so a slow one is
#: worth abandoning rather than queueing behind.
_SWEEP_TIMEOUT = 2.0
#: How many jobs may wait before callers are told the audio service is stuck.
_MAX_PENDING_JOBS = 16


def run_with_audio(function: Callable[[], object], timeout: float = _CALL_TIMEOUT) -> object:
    """Run ``function`` on the Core Audio thread and hand back its result."""
    global _AUDIO_THREAD
    with _AUDIO_LOCK:
        if _AUDIO_THREAD is None:
            _AUDIO_THREAD = _AudioThread()
        thread = _AUDIO_THREAD
    return thread.call(function, timeout)


@dataclass(slots=True)
class _Ducked:
    """One application we turned down, and the two levels that describes."""

    #: Executable name, used to find a replacement session if this one dies.
    app: str
    #: What the application played at before we touched it — restored verbatim.
    original: float
    #: What we set it to. Kept so the sweep can tell a session that drifted back
    #: up from one that is already where we want it.
    target: float


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
    from comtypes import CLSCTX_ALL
    from pycaw.api.audiopolicy import IAudioSessionControl2
    from pycaw.pycaw import AudioUtilities, IAudioSessionManager2, ISimpleAudioVolume

    enumerator = AudioUtilities.GetDeviceEnumerator()
    devices = enumerator.EnumAudioEndpoints(_E_CAPTURE, _DEVICE_ACTIVE)
    for index in range(devices.GetCount()):
        device = devices.Item(index)
        try:
            # QueryInterface, never cast. ``comtypes.cast`` is ``ctypes.cast``
            # re-exported, and casting a COM pointer builds a second smart
            # pointer over the same interface WITHOUT an AddRef. The temporary
            # returned by Activate() then dies at the end of this statement and
            # releases the manager to a refcount of zero — while ``manager``
            # still points at it. Every call below is a use-after-free, and the
            # eventual second Release lands on freed memory: an access
            # violation with no stable location, which is why it showed up
            # inside unrelated Core Audio calls, inside the garbage collector,
            # and as a swallowed "COM method call without VTable". Freed memory
            # usually still holds the old bytes, so it worked on most machines
            # most of the time. QueryInterface AddRefs, which is the contract
            # the pointer is destroyed under. pycaw does the same thing one
            # layer down for exactly this reason.
            manager = device.Activate(
                IAudioSessionManager2._iid_, CLSCTX_ALL, None
            ).QueryInterface(IAudioSessionManager2)
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
        #: process id -> what we did to that application's playback.
        self._ducked: dict[int, _Ducked] = {}
        #: Apps whose restore found no live session, retried on the next mute.
        #: Loaded from disk at startup, because the restore that never ran is
        #: most often the one a dead process was holding — see _remember().
        self._pending_unmutes: dict[str, str] = {}
        self._pending_restores: dict[str, tuple[str, float]] = {}
        self._recall()
        #: The thread re-ducking sessions born loud mid-recording, if running.
        self._watcher: threading.Thread | None = None
        self._stop_watching_now = threading.Event()
        #: mute() and unmute() have two independent callers — the hotkey, and a
        #: room telling us somebody else started talking — on different threads.
        #: Unserialised, two mutes could each start a watcher while only one
        #: handle is kept, leaving an orphan sweep that ducks the music back
        #: down after the restore and never stops. Reentrant because mute()
        #: calls unmute() to clear a recording whose restore never ran.
        #:
        #: The watcher thread must never take this lock: _stop_watcher() joins
        #: it while holding it. The watcher needs no lock — the Core Audio
        #: thread already serialises a sweep against a mute or a restore.
        self._api_lock = threading.RLock()
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
        with self._api_lock:
            # Whatever the previous recording left running, this one owns the
            # audio state now — including a watcher that ducked nothing and so
            # would not be stopped by the restore below.
            self._stop_watcher()
            if self._muted or self._ducked:
                # A leftover entry means a previous unmute never ran; better to
                # restore those sessions now than to lose track of them entirely.
                LOGGER.warning("Lista wyciszonych nie była pusta; przywracam poprzednie")
                self.unmute()
            try:
                run_with_audio(self._mute_now, timeout=_MUTE_TIMEOUT)
            except Exception:
                LOGGER.exception("Wyciszanie nie powiodło się; kontynuuję nagrywanie")
                return
            if self.config.duck_enabled:
                self._start_watcher()

    def _mute_now(self) -> None:
        # An app that vanished before its restore may be back by now. Fix it
        # BEFORE ducking, so the duck records the true original volume.
        self._retry_pending()
        self._mute_capture()
        if self.config.duck_enabled:
            self._duck()
        self._remember()

    def unmute(self) -> None:
        """Restore everything :meth:`mute` touched. Never raises."""
        with self._api_lock:
            # Before anything else, or a sweep still in flight lands after the
            # restore and leaves the music quiet for good.
            self._stop_watcher()
            if not self._muted and not self._ducked:
                return
            muted, self._muted = self._muted, {}
            ducked, self._ducked = self._ducked, {}
            try:
                run_with_audio(lambda: self._unmute_now(muted, ducked))
            except Exception:
                LOGGER.exception("Nie można przywrócić stanu audio")

    def _unmute_now(self, muted: dict[int, str], ducked: dict[int, _Ducked]) -> None:
        self._unmute_capture(muted)
        self._restore(ducked)
        self._remember()

    # -- microphones ---------------------------------------------------------

    def _mute_capture(self) -> None:
        wanted: set[str] = set()
        for name in self.config.apps:
            wanted |= _forms(name)
        if not wanted:
            return
        seen: set[str] = set()
        for session in capture_sessions():
            forms = _forms(session.app) & wanted
            if not forms:
                continue
            seen |= forms
            if session.volume.GetMute():
                # Nothing to set — mute is a flag, not a counter — and the
                # restore has to leave it exactly as found. But this used to be
                # a DEBUG line, which made it the quietest possible way for the
                # feature to do nothing at all: the flag outlives the session
                # that carried it in Windows' per-application store, so a stale
                # one silences this branch for good while the user, unmuted in
                # the application itself, is heard through the whole dictation.
                # Say it out loud instead.
                LOGGER.info(
                    "Mikrofon %s (pid %d) był już wyciszony; zostawiam bez zmian",
                    session.app,
                    session.pid,
                )
                continue
            session.volume.SetMute(1, None)
            self._muted[session.pid] = session.app
            LOGGER.info("Wyciszono mikrofon aplikacji %s (pid %d)", session.app, session.pid)
        absent = [name for name in self.config.apps if not _forms(name) & seen]
        if absent:
            # Not an error: an application that is not holding a microphone has
            # nothing to mute. Worth a line, because "nothing happened" and
            # "nothing needed to happen" look identical from the outside.
            LOGGER.info("Bez sesji mikrofonu, nie ma czego wyciszać: %s", ", ".join(absent))

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
        """Turn every playing session down to a fraction of its own level.

        The configured numbers multiply the app's current volume rather than
        naming a target, matching the Linux backend. An absolute target is a
        different effect depending on how loud the user already was: a light
        dip at full volume, silence for someone playing music quietly.

        Runs once when the recording starts and then on every sweep, which is
        what catches applications that only start playing mid-dictation.
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
            current = float(session.volume.GetMasterVolume())
            known = self._ducked.get(session.pid)
            if known is not None:
                self._hold_down(session, known, current)
                continue
            if current <= 0.0:
                # Already silent; nothing to take away and nothing to restore.
                continue
            if current < DUCK_FLOOR:
                LOGGER.debug(
                    "%s gra już na %.0f%%; nie ściszam poniżej podłogi %.0f%%",
                    session.app,
                    current * 100,
                    DUCK_FLOOR * 100,
                )
                continue
            target = round(current * factor, 2)
            if target >= current:
                # Rounding swallowed the whole reduction.
                continue
            session.volume.SetMasterVolume(target, None)
            self._ducked[session.pid] = _Ducked(session.app, current, target)
            LOGGER.info(
                "Ściszono %s z %.0f%% do %.0f%% (mnożnik %.2f)",
                session.app,
                current * 100,
                target * 100,
                factor,
            )

    @staticmethod
    def _hold_down(session: _Session, ducked: _Ducked, current: float) -> None:
        """Push an already-ducked application back down if it climbed back up.

        This is the track change: the stream we ducked ended, and the one
        Windows created for the next song was born at the application's own
        volume. The remembered original stays untouched — it is still what the
        user gets back — and only the new session is pulled down to the level
        the rest of the dictation is already playing at.
        """
        if current <= ducked.target + _DUCK_TOLERANCE:
            return
        session.volume.SetMasterVolume(ducked.target, None)
        LOGGER.info(
            "Ponownie ściszono %s do %.0f%% (nowy dźwięk w trakcie dyktowania)",
            ducked.app,
            ducked.target * 100,
        )

    def _restore(self, ducked: dict[int, _Ducked]) -> None:
        if not ducked:
            return
        restored: set[int] = set()
        for session in _playback_sessions():
            entry = ducked.get(session.pid)
            if entry is None:
                continue
            session.volume.SetMasterVolume(entry.original, None)
            restored.add(session.pid)
            LOGGER.info("Przywrócono głośność %s do %.0f%%", entry.app, entry.original * 100)
        for pid, entry in ducked.items():
            if pid in restored:
                continue
            if not self._restore_by_app(entry.app, entry.original):
                LOGGER.warning(
                    "Sesja %s zniknęła przed przywróceniem głośności; "
                    "spróbuję ponownie, gdy się pojawi",
                    entry.app,
                )
                self._pending_restores[entry.app.casefold()] = (entry.app, entry.original)

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

    # -- keeping the duck down -----------------------------------------------

    def _start_watcher(self) -> None:
        """Re-duck in the background for as long as the recording lasts."""
        if self._watcher is not None:
            return
        self._stop_watching_now.clear()
        self._watcher = threading.Thread(
            target=self._watch, name="voiceflow-duck", daemon=True
        )
        self._watcher.start()

    def _stop_watcher(self) -> None:
        """Stop the sweep and wait for the one in flight. Idempotent."""
        watcher, self._watcher = self._watcher, None
        if watcher is None:
            return
        self._stop_watching_now.set()
        # Joined, not just signalled: a sweep queued behind us on the Core Audio
        # thread would otherwise re-duck the sessions the restore just gave
        # back, and nothing would ever put them right again. The wait covers one
        # sweep; past that the service is wedged and the restore, sent after
        # this returns, still runs after the sweep because the queue is ordered.
        watcher.join(timeout=_SWEEP_TIMEOUT + _SWEEP_INTERVAL)

    def _watch(self) -> None:
        while not self._stop_watching_now.wait(_SWEEP_INTERVAL):
            try:
                run_with_audio(self._duck, timeout=_SWEEP_TIMEOUT)
            except Exception:  # noqa: BLE001 - one bad sweep is not fatal
                # Whatever went wrong may be over by the next tick, and the
                # recording's own restore path is unaffected either way.
                LOGGER.debug("Nie udało się odświeżyć ściszenia", exc_info=True)

    # -- deferred repairs ----------------------------------------------------

    # -- surviving our own death ---------------------------------------------

    def _state_file(self) -> Path:
        from voiceflow.paths import data_dir

        return data_dir() / "audio-restore.json"

    def _remember(self) -> None:
        """Write down what still owes the user their audio back.

        Everything above assumes the restore runs in this process. It did not
        on 18.08: the daemon ducked Discord from 100% to 30% and died 35 seconds
        later inside Core Audio, taking the only record of that 100% with it.
        Windows keeps a mixer level per application, so every Discord since was
        born at 30% — and the next dictation ducked *that*, then dutifully
        "restored" it. The number the user is owed cannot live only in memory.

        Written by application name, never by process id: the process this is
        meant to survive is the one whose ids stopped meaning anything.
        """
        owed_volumes = {
            entry.app.casefold(): [entry.app, entry.original] for entry in self._ducked.values()
        }
        owed_volumes.update(
            {key: [app, original] for key, (app, original) in self._pending_restores.items()}
        )
        owed_mutes = {app.casefold(): app for app in self._muted.values()}
        owed_mutes.update(self._pending_unmutes)
        path = self._state_file()
        try:
            if not owed_volumes and not owed_mutes:
                path.unlink(missing_ok=True)
                return
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(
                json.dumps({"volumes": owed_volumes, "mutes": owed_mutes}, ensure_ascii=False),
                encoding="utf-8",
            )
        except OSError as exc:
            # Best effort: a dictation must not fail over a bookkeeping file.
            LOGGER.debug("Nie można zapisać stanu audio do przywrócenia: %s", exc)

    def _recall(self) -> None:
        """Take over the debts of a daemon that did not live to pay them."""
        path = self._state_file()
        try:
            document = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return
        volumes = document.get("volumes") if isinstance(document, dict) else None
        mutes = document.get("mutes") if isinstance(document, dict) else None
        for key, value in (volumes or {}).items():
            try:
                app, original = value[0], float(value[1])
            except (TypeError, ValueError, IndexError):
                continue
            self._pending_restores.setdefault(key, (app, original))
        for key, app in (mutes or {}).items():
            if isinstance(app, str):
                self._pending_unmutes.setdefault(key, app)
        if self._pending_restores or self._pending_unmutes:
            # Repaired on the next dictation, by the retry that already exists:
            # doing it here would mean Core Audio work in a constructor, on
            # whatever thread happens to build the daemon.
            LOGGER.info(
                "Poprzedni demon nie zdążył przywrócić dźwięku: %s. "
                "Naprawię przy najbliższym dyktowaniu",
                ", ".join(
                    sorted(
                        [app for app, _ in self._pending_restores.values()]
                        + list(self._pending_unmutes.values())
                    )
                ),
            )

    def _retry_pending(self) -> None:
        """Fix apps whose restore failed because their session had gone."""
        for key, app in list(self._pending_unmutes.items()):
            if self._unmute_by_app(app):
                del self._pending_unmutes[key]
        for key, (app, original) in list(self._pending_restores.items()):
            if self._restore_by_app(app, original):
                del self._pending_restores[key]
