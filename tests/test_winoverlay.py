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
