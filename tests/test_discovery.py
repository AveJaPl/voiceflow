"""Rules for finding rooms on the local network. No bus, no network.

The Avahi side (`voiceflow_app.avahi`) is deliberately not imported here: it
needs `gi`, which this environment does not have, and it is a thin wrapper over
calls that only a real bus can answer. It was verified against a live Avahi.
"""

from __future__ import annotations

from voiceflow_app.discovery import (
    DiscoveredRoom,
    decode_txt,
    encode_txt,
    room_from_txt,
    visible_rooms,
)


def test_txt_round_trips():
    fields = {"code": "AB23CD", "room": "Salon", "host": "Filip"}

    assert decode_txt(encode_txt(fields)) == fields


def test_txt_survives_polish_letters_in_a_room_name():
    """Nazwę pokoju nadaje człowiek, więc „Świetlica" musi przejść w obie strony."""
    fields = {"code": "AB23CD", "room": "Świetlica", "host": "Paweł"}

    assert decode_txt(encode_txt(fields)) == fields


def test_record_without_an_equals_sign_is_skipped():
    assert decode_txt([list(b"code=AB23CD"), list(b"smieci")]) == {"code": "AB23CD"}


def test_record_that_is_not_utf8_is_skipped_instead_of_crashing():
    """W sieci bywa cudzy ruch; obcy bajt nie może wywrócić listy pokoi."""
    assert decode_txt([[0xFF, 0xFE], list(b"code=AB23CD")]) == {"code": "AB23CD"}


def test_empty_txt_is_an_empty_mapping():
    assert decode_txt([]) == {}
    assert decode_txt(None) == {}


def test_room_needs_a_code_to_be_a_room():
    """Wpis bez kodu dałby przycisk „Dołącz", który prowadzi donikąd."""
    assert room_from_txt({"room": "Salon"}) is None
    assert room_from_txt({"code": "   "}) is None


def test_code_is_normalised_to_upper_case():
    room = room_from_txt({"code": "ab23cd"})

    assert room is not None
    assert room.code == "AB23CD"


def test_room_without_a_name_falls_back_to_its_code():
    room = room_from_txt({"code": "AB23CD"})

    assert room.title == "Pokój AB23CD"
    assert room.subtitle == "AB23CD"


def test_named_room_shows_its_host():
    room = room_from_txt({"code": "AB23CD", "room": "Salon", "host": "Filip"})

    assert room.title == "Salon"
    assert room.subtitle == "Filip · AB23CD"


def test_own_room_is_not_offered_to_join():
    rooms = [DiscoveredRoom("AB23CD", "Salon", "Filip")]

    assert visible_rooms(rooms, own_code="ab23cd") == []


def test_same_room_from_two_interfaces_is_listed_once():
    """Ta sama maszyna zgłasza się po kablu i po Wi-Fi; to jeden pokój."""
    rooms = [
        DiscoveredRoom("AB23CD", "Salon", "Filip"),
        DiscoveredRoom("AB23CD", "Salon", "Filip"),
    ]

    assert visible_rooms(rooms) == [DiscoveredRoom("AB23CD", "Salon", "Filip")]


def test_order_of_discovery_is_preserved():
    rooms = [
        DiscoveredRoom("BBBBBB", "Drugi", ""),
        DiscoveredRoom("AAAAAA", "Pierwszy", ""),
    ]

    assert [room.code for room in visible_rooms(rooms)] == ["BBBBBB", "AAAAAA"]


def test_no_rooms_on_the_network_is_an_empty_list_not_an_error():
    assert visible_rooms([]) == []
