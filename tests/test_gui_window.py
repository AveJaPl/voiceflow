"""The Windows desktop window, built offscreen.

Qt renders to a headless platform plugin here, so these are real widgets with
real layouts — the pages are constructed, navigated and edited exactly as they
are in front of a user, without anyone having to look at a screen.

The daemon and the configuration file are stubbed: this suite is about the
window, and a test that needed a running daemon would be a test that fails on
every machine that is not the author's.
"""

from __future__ import annotations

import os
from typing import Any

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("PySide6", reason="okno desktopowe jest zależnością windowsową")

from PySide6.QtWidgets import QApplication  # noqa: E402

from voiceflow.gui import service  # noqa: E402
from voiceflow.gui.pages.dashboard import DashboardPage  # noqa: E402
from voiceflow.gui.pages.history import HistoryPage  # noqa: E402
from voiceflow.gui.pages.room import RoomPage  # noqa: E402
from voiceflow.gui.pages.sessions import SessionsPage  # noqa: E402
from voiceflow.gui.pages.settings import SettingsPage  # noqa: E402
from voiceflow.gui.pages.stats import StatsPage  # noqa: E402
from voiceflow.gui.pages.vocabulary import VocabularyPage  # noqa: E402
from voiceflow.gui.widgets import ClampedLabel, SettingsCard, SettingsRow, Switch  # noqa: E402


@pytest.fixture(scope="session")
def qt_app():
    """One QApplication for the whole session; Qt allows no second one."""
    application = QApplication.instance() or QApplication([])
    yield application


@pytest.fixture
def quiet(monkeypatch):
    """Cut every page off from the daemon, the network and the real config."""
    monkeypatch.setattr(service, "daemon_status", lambda: None)
    monkeypatch.setattr(service, "history_records", lambda limit=None: [])
    monkeypatch.setattr(service, "load_raw_config", lambda path=None: {})
    monkeypatch.setattr(service, "discover_audio_applications", list)
    monkeypatch.setattr(service, "discord_available", lambda: False)
    monkeypatch.setattr(service, "newer_release", lambda: None)
    monkeypatch.setattr(service, "room_state", lambda: __import__(
        "voiceflow.roomstate", fromlist=["RoomState"]
    ).RoomState())


def _record(timestamp: str, words: int = 10, text: str | None = "tekst") -> dict[str, Any]:
    return {
        "timestamp": timestamp,
        "words": words,
        "chars": words * 6,
        "audio_seconds": words * 0.4,
        "transcription_seconds": 0.2,
        "injected": True,
        "text": text,
    }


# -- the shell ---------------------------------------------------------------


def test_the_window_carries_the_same_seven_pages_as_the_gtk_application(qt_app, quiet) -> None:
    from voiceflow.gui.app import NAVIGATION, MainWindow

    window = MainWindow()
    assert list(window._pages) == [entry[0] for entry in NAVIGATION]
    assert list(window._pages) == [
        "dashboard", "history", "stats", "room", "sessions", "vocabulary", "settings"
    ]
    window.close()


def test_navigating_moves_the_title_into_the_window_bar(qt_app, quiet) -> None:
    from voiceflow.gui.app import MainWindow

    window = MainWindow()
    window.show_page("room")
    assert window.header_title.text() == "Pokój"
    assert window._stack.currentWidget() is window.room
    window.close()


def test_the_unsaved_bar_appears_only_on_the_pages_that_own_settings(qt_app, quiet) -> None:
    from voiceflow.gui.app import MainWindow

    window = MainWindow()
    window._set_dirty()
    window.show_page("settings")
    assert window.dirty_bar.isVisibleTo(window)
    window.show_page("stats")
    assert not window.dirty_bar.isVisibleTo(window)
    window.close()


def test_closing_the_window_withdraws_the_room_advertisement(qt_app, quiet) -> None:
    from voiceflow.gui.app import MainWindow

    window = MainWindow()
    withdrawn: list[bool] = []
    window.room._advertiser.withdraw = lambda: withdrawn.append(True)
    window.close()
    assert withdrawn, "pokój przestaje być rozgłaszany, gdy nikt na niego nie patrzy"


# -- the overview ------------------------------------------------------------


def test_an_absent_daemon_disables_dictation_rather_than_pretending(qt_app, quiet) -> None:
    page = DashboardPage(lambda: None, lambda: None, lambda _text: None)
    page.set_status(None)
    assert page.state_label.text() == "Demon nie działa"
    assert not page.toggle_button.isEnabled()
    assert page.service_button.text() == "Uruchom demona"
    assert page.daemon_online is False


def test_recording_shows_the_pulse_and_offers_to_stop(qt_app, quiet) -> None:
    page = DashboardPage(lambda: None, lambda: None, lambda _text: None)
    page.set_status({"state": "RECORDING", "model": "large-v3-turbo", "device": "cuda"})
    assert page.toggle_button.text() == "Zatrzymaj"
    assert page.toggle_button.objectName() == "recording-action"
    assert page.meta_label.text() == "large-v3-turbo · GPU"


def test_a_shortcut_windows_refused_is_reported_not_merely_named(qt_app, quiet) -> None:
    page = DashboardPage(lambda: None, lambda: None, lambda _text: None)
    page.set_status(
        {
            "state": "IDLE",
            "hotkey": "ctrl+shift+space",
            "hotkey_active": False,
            "hotkey_error": "zajmuje go Foo",
        }
    )
    assert "NIE działa" in page.hotkey_label.text()
    assert "zajmuje go Foo" in page.hotkey_label.text()


def test_the_overview_counts_today_against_yesterday(qt_app, quiet) -> None:
    from datetime import datetime, timedelta

    now = datetime.now().astimezone()
    page = DashboardPage(lambda: None, lambda: None, lambda _text: None)
    page.update_history(
        [
            _record((now - timedelta(days=1)).isoformat(), 30),
            _record(now.isoformat(), 50),
        ]
    )
    assert page.today_card._value.text() == "50"
    assert page.today_card._trend.text() == "+20 vs wczoraj"
    assert page.total_card._trend.text() == "2 dyktowań"


# -- history -----------------------------------------------------------------


def test_history_groups_by_day_and_searches_the_text(qt_app, quiet) -> None:
    from datetime import datetime, timedelta

    now = datetime.now().astimezone()
    page = HistoryPage(lambda _text: None, lambda _record: None)
    page.update_history(
        [
            _record((now - timedelta(days=1)).isoformat(), 10, "wczorajszy raport"),
            _record(now.isoformat(), 20, "dzisiejsza notatka"),
        ]
    )
    assert page._list.count() == 2, "dwa dni, dwie grupy"
    page.search.setText("raport")
    assert page._list.count() == 1
    page.search.setText("czegoś takiego nie ma")
    assert page._list.count() == 1, "pusty wynik to jedna karta z komunikatem"


def test_deleting_an_entry_takes_two_presses(qt_app, quiet) -> None:
    from datetime import datetime

    deleted: list[Any] = []
    page = HistoryPage(lambda _text: None, deleted.append)
    page.update_history([_record(datetime.now().astimezone().isoformat(), 10, "coś")])
    card = page._list.itemAt(0).widget().layout().itemAt(1).widget()
    card._on_delete()
    assert not deleted, "pierwsze kliknięcie tylko pyta"
    assert card._delete_button.text() == "Potwierdź usunięcie"
    card._on_delete()
    assert deleted, "drugie kliknięcie usuwa"


def test_a_long_entry_is_cut_with_an_ellipsis_not_mid_word(qt_app) -> None:
    label = ClampedLabel("słowo " * 200, lines=2)
    label.resize(200, 40)
    label._relayout()
    assert label.text().endswith("…")
    assert len(label.text()) < 200


# -- vocabulary --------------------------------------------------------------


def test_vocabulary_round_trips_through_the_configuration(qt_app, quiet) -> None:
    dirtied: list[bool] = []
    page = VocabularyPage(lambda: dirtied.append(True), lambda _message: None)
    page.load_config({"model": {"vocabulary": ["Kubernetes"], "name": "large-v3-turbo"}})
    page.entry.setText("PipeWire")
    page._on_add()
    written: dict[str, Any] = {"model": {"name": "large-v3-turbo", "beam_size": 5}}
    page.apply_to_config(written)
    assert written["model"]["vocabulary"] == ["Kubernetes", "PipeWire"]
    assert written["model"]["beam_size"] == 5, "nieznane klucze przeżywają zapis"
    assert dirtied


def test_the_same_term_twice_is_refused_with_a_message(qt_app, quiet) -> None:
    messages: list[str] = []
    page = VocabularyPage(lambda: None, messages.append)
    page.load_config({"model": {"vocabulary": ["Whisper"]}})
    page.entry.setText("whisper")
    page._on_add()
    assert messages == ["Ten termin jest już w słowniku"]


# -- settings ----------------------------------------------------------------


def test_settings_preserve_keys_the_window_does_not_know(qt_app, quiet) -> None:
    page = SettingsPage(lambda: None, lambda _message: None)
    page.load_config({"model": {"name": "large-v3-turbo"}})
    written: dict[str, Any] = {"model": {"wlasny_klucz": 1}, "cos_zupelnie_innego": True}
    page.apply_to_config(written)
    assert written["model"]["wlasny_klucz"] == 1
    assert written["cos_zupelnie_innego"] is True


def test_the_ducking_slider_is_written_as_a_fraction(qt_app, quiet) -> None:
    page = SettingsPage(lambda: None, lambda _message: None)
    page.load_config({"mute_apps": {"duck_to": 0.6}})
    assert page.default_duck_scale.value() == 60
    assert page.default_duck_value.text() == "60% obecnej"
    page.default_duck_scale.setValue(25)
    written: dict[str, Any] = {}
    page.apply_to_config(written)
    assert written["mute_apps"]["duck_to"] == 0.25


def test_a_full_slider_says_it_does_not_quieten_anything(qt_app, quiet) -> None:
    page = SettingsPage(lambda: None, lambda _message: None)
    page.load_config({})
    page.default_duck_scale.setValue(100)
    assert page.default_duck_value.text() == "100% · nie ściszaj"


def test_per_application_rules_get_their_own_slider(qt_app, quiet) -> None:
    page = SettingsPage(lambda: None, lambda _message: None)
    page.load_config({"mute_apps": {"duck_to": 0.6, "duck_rules": {"Spotify.exe": 0.25}}})
    assert "Spotify.exe" in page._rule_widgets
    scale, value = page._rule_widgets["Spotify.exe"]
    assert scale.value() == 25
    assert value.text() == "25% obecnej"


def test_moving_the_default_moves_only_the_applications_without_a_rule(qt_app, quiet) -> None:
    page = SettingsPage(lambda: None, lambda _message: None)

    class _App:
        def __init__(self, name):
            self.name, self.playing, self.capturing = name, True, False

    page.load_config({"mute_apps": {"duck_to": 0.6, "duck_rules": {"Spotify.exe": 0.25}}})
    page._detected_audio_apps = {"Spotify.exe": _App("Spotify.exe"), "opera.exe": _App("opera.exe")}
    page._render_duck_apps()
    page.default_duck_scale.setValue(80)
    assert page._rule_widgets["opera.exe"][0].value() == 80
    assert page._rule_widgets["Spotify.exe"][0].value() == 25, "własna reguła wygrywa z domyślną"


def test_removing_a_rule_drops_it_from_what_gets_written(qt_app, quiet) -> None:
    page = SettingsPage(lambda: None, lambda _message: None)
    page.load_config({"mute_apps": {"duck_rules": {"Spotify.exe": 0.25}}})
    page._remove_duck_rule("Spotify.exe")
    written: dict[str, Any] = {}
    page.apply_to_config(written)
    assert written["mute_apps"]["duck_rules"] == {}


def test_a_microphone_application_can_be_toggled_onto_the_mute_list(qt_app, quiet) -> None:
    page = SettingsPage(lambda: None, lambda _message: None)
    page.load_config({"mute_apps": {"apps": []}})
    page._toggle_mute_app("Discord.exe", True)
    written: dict[str, Any] = {}
    page.apply_to_config(written)
    assert written["mute_apps"]["apps"] == ["Discord.exe"]
    page._toggle_mute_app("discord.exe", False)
    page.apply_to_config(written)
    assert written["mute_apps"]["apps"] == [], "porównanie nazw ignoruje wielkość liter"


def test_switching_the_ducking_off_disables_every_slider(qt_app, quiet) -> None:
    page = SettingsPage(lambda: None, lambda _message: None)
    page.load_config({"mute_apps": {"duck_enabled": True, "duck_rules": {"Spotify.exe": 0.3}}})
    page.duck_row.set_checked(False)
    page._set_duck_controls_enabled()
    assert not page.default_duck_scale.isEnabled()
    assert not page._rule_widgets["Spotify.exe"][0].isEnabled()


def test_loading_the_form_does_not_count_as_an_edit(qt_app, quiet) -> None:
    dirtied: list[bool] = []
    page = SettingsPage(lambda: dirtied.append(True), lambda _message: None)
    page.load_config({"model": {"name": "small", "device": "cpu"}, "mute_apps": {"duck_to": 0.4}})
    assert not dirtied, "wypełnianie pól nie jest zmianą użytkownika"
    page.paste_entry.setText("ctrl+shift+v")
    assert dirtied


# -- the room ----------------------------------------------------------------


def test_a_machine_outside_a_room_is_offered_the_way_in(qt_app, quiet) -> None:
    page = RoomPage(lambda _message: None)
    page._enabled = False
    page._code = ""
    page._render()
    assert page._outside.isVisibleTo(page)
    assert not page._inside.isVisibleTo(page)


def test_a_machine_inside_a_room_sees_the_board(qt_app, quiet) -> None:
    page = RoomPage(lambda _message: None)
    page._enabled = True
    page._code = "K7QP2M"
    page._document = {
        "room": {"name": "Salon"},
        "ranking": [{"name": "Filip", "words": 100, "seconds": 60,
                     "dictations": 3, "averageWords": 33}],
    }
    page._render()
    assert page._inside.isVisibleTo(page)
    assert page._room_title.text() == "Salon · K7QP2M"
    assert page._board_holder.count() == 1


def test_somebody_else_speaking_explains_why_the_shortcut_is_dead(qt_app, quiet) -> None:
    from voiceflow.roomstate import RoomState

    page = RoomPage(lambda _message: None)
    page._enabled, page._code = True, "K7QP2M"
    page._state = RoomState(code="K7QP2M", connected=True, speaking="Filip")
    page._render()
    assert page._now_title.text() == "Filip dyktuje"
    assert "nie zacznie nagrywać" in page._now_subtitle.text()


def test_a_daemon_that_never_reported_is_not_called_disconnected(qt_app, quiet) -> None:
    from voiceflow.roomstate import RoomState

    page = RoomPage(lambda _message: None)
    page._enabled, page._code = True, "K7QP2M"
    page._state = RoomState()
    page._render()
    assert "nie zgłosił jeszcze" in page._now_subtitle.text()


def test_an_empty_network_says_so_instead_of_showing_nothing(qt_app, quiet) -> None:
    page = RoomPage(lambda _message: None)
    page._discovered = []
    page._render_nearby()
    assert page._nearby_holder.count() == 1


# -- sessions ----------------------------------------------------------------


def test_sessions_outside_a_room_point_back_at_the_room_tab(qt_app, quiet) -> None:
    page = SessionsPage(lambda _message: None)
    page._code = ""
    page._render()
    assert page._history_holder.count() == 1


def test_a_running_session_is_marked_as_running(qt_app, quiet) -> None:
    page = SessionsPage(lambda _message: None)
    page._code = page._loaded_for = "K7QP2M"
    page._sessions = [
        {"name": "coding", "startedAt": "2026-08-11T10:00:00Z", "endedAt": None,
         "speakers": 2, "dictations": 10, "words": 500, "seconds": 300}
    ]
    page._render()
    card = page._history_holder.itemAt(0).widget()
    title = card.body.itemAt(0).widget().layout().itemAt(0).widget()
    assert title.text() == "coding — trwa"


def test_an_unfetched_room_is_loading_not_empty(qt_app, quiet) -> None:
    page = SessionsPage(lambda _message: None)
    page._code = "K7QP2M"
    page._loaded_for = ""
    page._sessions = []
    page._render()
    message = page._history_holder.itemAt(0).widget()
    assert "Wczytywanie" in message.body.itemAt(1).widget().text()


# -- statistics --------------------------------------------------------------


def test_statistics_hide_behind_an_empty_state_until_there_is_history(qt_app, quiet) -> None:
    page = StatsPage()
    page.update_history([])
    assert not page._content.isVisibleTo(page)
    from datetime import datetime

    page.update_history([_record(datetime.now().astimezone().isoformat(), 42)])
    assert page._summary["words"].text() == "42"


# -- the pieces --------------------------------------------------------------


def test_the_switch_lands_on_its_final_position_when_loaded(qt_app) -> None:
    switch = Switch(False)
    switch.setChecked(True)
    assert switch.isChecked()
    assert switch.offset == 1.0, "wczytanie formularza nie animuje się jak klik"


def test_only_the_last_row_of_a_card_has_no_separator(qt_app) -> None:
    card = SettingsCard()
    first, second = SettingsRow("Pierwszy"), SettingsRow("Drugi")
    card.append(first)
    card.append(second)
    assert first.property("last") == "false"
    assert second.property("last") == "true"
    card.remove(second)
    assert first.property("last") == "true"


# -- advertising the room ------------------------------------------------------


class _Advertiser:
    """Records what the page asked the network to announce."""

    def __init__(self) -> None:
        self.published: list[dict[str, str]] = []
        self.withdrawn = 0

    def publish(self, **fields: str) -> None:
        self.published.append(fields)

    def withdraw(self) -> None:
        self.withdrawn += 1


def test_a_machine_outside_a_room_announces_nothing(qt_app, quiet) -> None:
    page = RoomPage(lambda _message: None)
    page._advertiser = _Advertiser()
    page._enabled, page._code = False, ""
    page._sync_advertisement()
    assert page._advertiser.published == []
    assert page._advertiser.withdrawn == 1


def test_being_in_a_room_announces_its_code_name_and_host(qt_app, quiet) -> None:
    page = RoomPage(lambda _message: None)
    page._advertiser = _Advertiser()
    page._enabled, page._code = True, "K7QP2M"
    page._document = {"room": {"name": "Salon"}}
    page._display_name.setText("Jakub")
    page._sync_advertisement()
    assert page._advertiser.published == [
        {"code": "K7QP2M", "name": "Salon", "host": "Jakub"}
    ]


def test_switching_the_announcement_off_withdraws_it(qt_app, quiet) -> None:
    page = RoomPage(lambda _message: None)
    page._advertiser = _Advertiser()
    page._enabled, page._code = True, "K7QP2M"
    page._on_advertise_toggled(False)
    assert page._advertiser.published == []
    assert page._advertiser.withdrawn >= 1


def test_a_room_found_nearby_becomes_a_card_that_can_be_joined(qt_app, quiet) -> None:
    from voiceflow.roomdiscovery import DiscoveredRoom

    joined: list[str] = []
    page = RoomPage(lambda _message: None)
    page._join = joined.append
    page._discovered = [DiscoveredRoom("AB12CD", "Biuro", "Ala")]
    page._render_nearby()
    assert page._nearby_holder.count() == 1
    card = page._nearby_holder.itemAt(0).widget()
    button = card.body.itemAt(1).widget()
    assert button.text() == "Dołącz"
    button.click()
    assert joined == ["AB12CD"]


def test_our_own_room_is_not_offered_back_to_us_on_screen(qt_app, quiet) -> None:
    from voiceflow.roomdiscovery import DiscoveredRoom

    page = RoomPage(lambda _message: None)
    page._code = "AB12CD"
    page._discovered = [DiscoveredRoom("AB12CD", "Biuro", "Ala")]
    page._render_nearby()
    card = page._nearby_holder.itemAt(0).widget()
    assert "Nikt w tej sieci" in card.body.itemAt(1).widget().text()


def test_the_board_lists_somebody_who_joined_and_said_nothing(qt_app, quiet) -> None:
    page = RoomPage(lambda _message: None)
    page._enabled, page._code = True, "K7QP2M"
    page._document = {
        "room": {"name": "Salon"},
        "ranking": [{"deviceId": "d1", "name": "Filip", "words": 100,
                     "seconds": 60, "dictations": 3, "averageWords": 33}],
        "members": [{"id": "d1", "name": "Filip"}, {"id": "d2", "name": "Jakub"}],
    }
    page._render_board()
    assert page._board_holder.count() == 2

    second = page._board_holder.itemAt(1).widget()
    middle = second.body.itemAt(1).widget().layout()
    assert middle.itemAt(0).widget().text() == "Jakub"
    assert "jeszcze nic nie podyktował" in middle.itemAt(2).widget().text()


def test_an_empty_room_says_nobody_joined_rather_than_nobody_spoke(qt_app, quiet) -> None:
    page = RoomPage(lambda _message: None)
    page._enabled, page._code = True, "K7QP2M"
    page._document = {"ranking": [], "members": []}
    page._render_board()
    card = page._board_holder.itemAt(0).widget()
    assert "nie dołączył" in card.body.itemAt(1).widget().text()
