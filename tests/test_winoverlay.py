"""The Windows overlay's one rule: never hold the focus the paste needs.

tkinter takes the foreground the moment it realizes a window, so the card gives
it straight back — and only ever its own theft. These pin that guard down; the
window itself needs a display and is exercised by hand.
"""

from __future__ import annotations

import pytest

from voiceflow.winplat import overlay


class FakeUser32:
    """Just enough user32: who is in front, and who is asked to be."""

    def __init__(self, foreground: int) -> None:
        self.foreground = foreground
        self.requested: list[int] = []

    def GetForegroundWindow(self) -> int:  # noqa: N802 - Win32 naming
        return self.foreground

    def SetForegroundWindow(self, window: int) -> int:  # noqa: N802
        self.requested.append(window)
        self.foreground = window
        return 1


@pytest.fixture
def user32(monkeypatch):
    def install(foreground: int) -> FakeUser32:
        fake = FakeUser32(foreground)
        monkeypatch.setattr(overlay, "_user32", lambda: fake)
        return fake

    return install


def test_the_card_gives_back_the_focus_it_took(user32):
    fake = user32(foreground=200)  # the overlay is in front

    overlay.hand_back_foreground(100, 200)

    assert fake.requested == [100]


def test_a_window_the_user_chose_is_left_in_front(user32):
    fake = user32(foreground=300)  # neither the editor nor the overlay

    overlay.hand_back_foreground(100, 200)

    assert fake.requested == []


@pytest.mark.parametrize(
    ("previous", "ours"),
    [(0, 200), (100, 0), (100, 100)],
    ids=["nothing-was-in-front", "no-card-of-ours", "same-window"],
)
def test_nothing_to_hand_back(user32, previous, ours):
    fake = user32(foreground=ours)

    overlay.hand_back_foreground(previous, ours)

    assert fake.requested == []


def test_foreground_window_survives_a_missing_desktop(monkeypatch):
    def explode():
        raise OSError("brak pulpitu")

    monkeypatch.setattr(overlay, "_user32", explode)

    assert overlay.foreground_window() == 0


class _FakeWidget:
    """A Tk widget that accepts anything and answers with numbers where asked."""

    def __init__(self, *args, **kwargs) -> None:
        pass

    def __getattr__(self, name: str):
        if name.startswith("winfo_"):
            return lambda *a, **k: 64
        return lambda *a, **k: None


class _FakeRoot(_FakeWidget):
    """Just enough Tk root: an ``after`` queue and a ``mainloop`` that drains it."""

    def __init__(self) -> None:
        self.pending: list = []
        self.destroyed = False

    def after(self, _ms: int, callback) -> None:
        self.pending.append(callback)

    def destroy(self) -> None:
        self.destroyed = True

    def mainloop(self) -> None:
        import time

        while not self.destroyed:
            callbacks, self.pending = self.pending, []
            for callback in callbacks:
                callback()
            time.sleep(0.005)


def test_the_card_thread_joins_the_mta_before_tk_and_collects_its_own_widgets(
    monkeypatch,
) -> None:
    """Both kinds of thread-bound objects in the daemon are handled on the card's
    thread: COM's apartment is joined before Tk can pick a single-threaded one,
    and the widgets are collected here, once the card is down, so no other
    thread's collector ever finalizes them (Tcl aborts the process if one does)."""
    import gc
    import sys
    import threading
    import types

    from voiceflow.config import OverlayConfig

    events: list[tuple[str, str]] = []

    def note(kind: str) -> None:
        events.append((kind, threading.current_thread().name))

    monkeypatch.setitem(
        sys.modules,
        "comtypes",
        types.SimpleNamespace(COINIT_MULTITHREADED=0, CoInitializeEx=lambda flags: note("mta")),
    )

    def fake_tk() -> _FakeRoot:
        note("tk")
        return _FakeRoot()

    monkeypatch.setitem(
        sys.modules, "tkinter", types.SimpleNamespace(Tk=fake_tk, Frame=_FakeWidget, Label=_FakeWidget)
    )
    real_collect = gc.collect

    def recording_collect(*args, **kwargs):
        note("gc")
        return real_collect(*args, **kwargs)

    monkeypatch.setattr(gc, "collect", recording_collect)

    card = overlay.WinOverlay(OverlayConfig(enabled=True))
    card.start("listening")
    card.stop()

    on_card_thread = [kind for kind, thread in events if thread == "voiceflow-overlay"]
    assert on_card_thread == ["mta", "tk", "gc"]
    assert not card.is_running
