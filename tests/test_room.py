"""Tests for the room client. No network, no server, no sockets."""

from __future__ import annotations

from voiceflow.config import RoomConfig
from voiceflow.room import RoomClient


class _Transport:
    """Records what was sent and lets a test push server messages in."""

    def __init__(self) -> None:
        self.sent: list[dict] = []
        self._on_message = None

    def send(self, payload: dict) -> None:
        self.sent.append(payload)

    def on_message(self, callback) -> None:
        self._on_message = callback

    def deliver(self, payload: dict) -> None:
        assert self._on_message is not None, "klient nie podpiął odbioru"
        self._on_message(payload)


def _client(**overrides):
    transport = _Transport()
    ducked: list[str] = []
    config = RoomConfig(
        enabled=True, server="wss://example", code="ROOM01", token="tok", **overrides
    )
    client = RoomClient(
        config,
        on_remote_speaking=lambda name: ducked.append(name),
        on_remote_silence=lambda: ducked.append("<cisza>"),
        transport=transport,
    )
    return client, transport, ducked


def test_free_room_allows_dictation() -> None:
    client, _transport, _ducked = _client()

    assert client.may_start() == (True, None)


def test_someone_else_speaking_blocks_with_their_name() -> None:
    client, transport, _ducked = _client()

    transport.deliver({"type": "speaker_changed", "speaking": {"name": "Wojtek", "deviceId": "w"}})

    assert client.may_start() == (False, "Wojtek")


def test_remote_speaker_ducks_local_audio_and_silence_restores_it() -> None:
    client, transport, ducked = _client()

    transport.deliver({"type": "speaker_changed", "speaking": {"name": "Wojtek", "deviceId": "w"}})
    transport.deliver({"type": "speaker_changed", "speaking": None})

    assert ducked == ["Wojtek", "<cisza>"]


def test_ducking_can_be_switched_off_locally() -> None:
    """Quietening this machine for somebody else is a permission, not a duty."""
    client, transport, ducked = _client(duck_for_others=False)

    transport.deliver({"type": "speaker_changed", "speaking": {"name": "Wojtek", "deviceId": "w"}})

    assert ducked == []
    assert client.may_start() == (False, "Wojtek"), "blokada działa niezależnie od ściszania"


def test_repeated_state_for_the_same_speaker_does_not_duck_twice() -> None:
    """A second duck would record the already-ducked volume as the original."""
    client, transport, ducked = _client()

    transport.deliver({"type": "speaker_changed", "speaking": {"name": "Wojtek", "deviceId": "w"}})
    transport.deliver({"type": "room_state", "speaking": {"name": "Wojtek", "deviceId": "w"}})

    assert ducked == ["Wojtek"]


def test_lost_connection_unblocks_rather_than_traps() -> None:
    """A room the client cannot reach must not take dictation away."""
    client, transport, ducked = _client()
    transport.deliver({"type": "speaker_changed", "speaking": {"name": "Wojtek", "deviceId": "w"}})

    client.on_disconnected()

    assert client.may_start() == (True, None)
    assert ducked == ["Wojtek", "<cisza>"], "cudze ściszenie jest cofane przy utracie łączności"


def test_finished_dictation_reports_only_numbers() -> None:
    client, transport, _ducked = _client()

    client.report_started()
    client.report_finished(words=12, seconds=4.25)

    assert transport.sent[-2] == {"type": "speaking_started"}
    assert transport.sent[-1] == {"type": "speaking_ended", "words": 12, "seconds": 4.25}
    assert all("text" not in message for message in transport.sent), "treść nigdy nie wychodzi"


def test_disabled_room_never_blocks_and_sends_nothing() -> None:
    transport = _Transport()
    client = RoomClient(
        RoomConfig(enabled=False),
        on_remote_speaking=lambda name: None,
        on_remote_silence=lambda: None,
        transport=transport,
    )

    client.report_started()
    client.report_finished(words=5, seconds=2)

    assert client.may_start() == (True, None)
    assert transport.sent == [], "wyłączony pokój nie wysyła niczego"


def test_denial_from_server_records_who_blocks() -> None:
    client, transport, _ducked = _client()

    transport.deliver({"type": "speaking_denied", "blockedBy": "Wojtek"})

    assert client.may_start() == (False, "Wojtek")


def test_broken_transport_does_not_break_dictation() -> None:
    """Reporting is best-effort: the dictation already happened locally."""

    class _Broken:
        def send(self, payload: dict) -> None:
            raise OSError("sieć padła")

        def on_message(self, callback) -> None:
            return None

    client = RoomClient(
        RoomConfig(enabled=True, server="wss://example", code="ROOM01", token="tok"),
        on_remote_speaking=lambda name: None,
        on_remote_silence=lambda: None,
        transport=_Broken(),
    )

    client.report_finished(words=3, seconds=1.0)  # nie może rzucić


def test_every_cli_command_is_dispatched() -> None:
    """A subcommand the parser knows but main() ignores falls through silently.

    That is exactly how `voiceflow room` shipped once already: the parser
    accepted it, nothing handled it, and it was forwarded to the daemon as an
    unknown command. Comparing the two lists catches the next one.
    """
    import inspect

    from voiceflow import cli

    parser = cli.build_parser()
    known = set()
    for action in parser._subparsers._group_actions:  # noqa: SLF001
        known.update(action.choices)

    source = inspect.getsource(cli.main)
    undispatched = {
        command
        for command in known
        if f'"{command}"' not in source
    }
    # `quit` is translated to the wire-level name, the rest fall through to the
    # daemon client on purpose.
    forwarded = {"toggle", "start", "stop", "cancel", "quit"}
    assert undispatched <= forwarded, f"komendy bez obsługi w main(): {undispatched - forwarded}"


# --- stan wystawiany aplikacji desktopowej --------------------------------
#
# Aplikacja chodzi w innym środowisku Pythona i nie zaimportuje niczego stąd,
# więc "kto teraz mówi" jedzie do niej plikiem. Te testy pilnują reguł, które
# ten plik wypełniają — bez dotykania dysku.


def _client_with_states(**overrides):
    transport = _Transport()
    states: list = []
    config = RoomConfig(
        enabled=True, server="wss://example", code="ROOM01", token="tok", **overrides
    )
    client = RoomClient(
        config,
        on_remote_speaking=lambda _name: None,
        on_remote_silence=lambda: None,
        transport=transport,
        on_state_changed=states.append,
    )
    return client, transport, states


def test_first_message_marks_the_link_as_connected() -> None:
    """Protokół nie ma zdarzenia "połączono"; ruch w kanale jest dowodem."""
    client, transport, states = _client_with_states()

    transport.deliver({"type": "room_state", "speaking": None})

    assert states, "żaden stan nie został opublikowany"
    assert states[0].connected is True
    assert states[0].code == "ROOM01"


def test_remote_speaker_lands_in_the_state() -> None:
    client, transport, states = _client_with_states()

    transport.deliver({"type": "speaker_changed", "speaking": {"name": "Wojtek"}})

    assert states[-1].speaking == "Wojtek"
    assert states[-1].speaking_here is False


def test_own_dictation_is_reported_apart_from_the_remote_speaker() -> None:
    """Serwer nigdy nie odsyła mówiącemu jego samego, więc bez tego pola
    aplikacja nie odróżniłaby własnego dyktowania od ciszy."""
    client, _transport, states = _client_with_states()

    client.report_started()

    assert states[-1].speaking_here is True
    assert states[-1].speaking is None


def test_finishing_clears_own_dictation() -> None:
    client, _transport, states = _client_with_states()
    client.report_started()

    client.report_finished(words=12, seconds=3.0)

    assert states[-1].speaking_here is False


def test_cancelling_clears_own_dictation() -> None:
    client, _transport, states = _client_with_states()
    client.report_started()

    client.report_cancelled()

    assert states[-1].speaking_here is False


def test_disconnect_publishes_a_disconnected_state() -> None:
    client, transport, states = _client_with_states()
    transport.deliver({"type": "speaker_changed", "speaking": {"name": "Wojtek"}})

    client.on_disconnected()

    assert states[-1].connected is False
    assert states[-1].speaking is None


def test_state_writer_that_throws_does_not_break_dictation() -> None:
    """Rysowanie cudzego okna nie może przewrócić nagrywania."""
    transport = _Transport()
    client = RoomClient(
        RoomConfig(enabled=True, server="wss://example", code="ROOM01", token="tok"),
        on_remote_speaking=lambda _name: None,
        on_remote_silence=lambda: None,
        transport=transport,
        on_state_changed=lambda _state: (_ for _ in ()).throw(OSError("dysk pełny")),
    )

    client.report_started()

    assert transport.sent == [{"type": "speaking_started"}]


# --- co teraz gra ----------------------------------------------------------


def test_track_is_sent_once_not_on_every_poll() -> None:
    """Odczyt leci co kilka sekund, a utwór zmienia się raz na piosenkę."""
    client, transport, _states = _client_with_states()
    track = {"title": "Numb", "artist": "Linkin Park", "player": "Spotify", "artUrl": ""}

    client.report_now_playing(track)
    client.report_now_playing(track)
    client.report_now_playing(track)

    assert transport.sent == [{"type": "now_playing", "track": track}]


def test_new_track_is_sent() -> None:
    client, transport, _states = _client_with_states()
    client.report_now_playing({"title": "Numb"})

    client.report_now_playing({"title": "In The End"})

    assert transport.sent[-1]["track"]["title"] == "In The End"


def test_silence_clears_the_tile() -> None:
    client, transport, _states = _client_with_states()
    client.report_now_playing({"title": "Numb"})

    client.report_now_playing(None)

    assert transport.sent[-1] == {"type": "now_playing", "track": None}


def test_reconnect_resends_the_track() -> None:
    """Serwer trzyma kafelek w pamięci procesu i gubi go razem z połączeniem."""
    client, transport, _states = _client_with_states()
    client.report_now_playing({"title": "Numb"})
    transport.sent.clear()

    client.on_disconnected()
    client.report_now_playing({"title": "Numb"})

    assert transport.sent == [{"type": "now_playing", "track": {"title": "Numb"}}]
