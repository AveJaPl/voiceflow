"""Room discovery rules on the package side — no bus, no network.

The Linux transport is Avahi and the Windows one is zeroconf, and the two hand
their TXT records over in different shapes. Both are decoded here, because a
room advertised from a Linux laptop has to appear in the Windows window.
"""

from __future__ import annotations

from voiceflow.roomdiscovery import (
    SERVICE_TYPE,
    ZEROCONF_TYPE,
    DiscoveredRoom,
    decode_txt,
    room_from_txt,
    txt_fields,
    visible_rooms,
)


def _avahi_record(**fields: str) -> list[list[int]]:
    """The byte-array-per-pair shape Avahi hands back."""
    return [list(f"{key}={value}".encode("utf-8")) for key, value in fields.items()]


# -- the wire format ---------------------------------------------------------


def test_the_zeroconf_type_is_the_avahi_type_plus_its_domain() -> None:
    assert ZEROCONF_TYPE == f"{SERVICE_TYPE}.local."


def test_the_advertised_record_carries_code_name_and_host() -> None:
    assert txt_fields("k7qp2m", "Salon", "Filip") == {
        "code": "K7QP2M",
        "room": "Salon",
        "host": "Filip",
    }


def test_the_code_is_advertised_upper_case_whatever_was_typed() -> None:
    assert txt_fields("k7qp2m", "", "")["code"] == "K7QP2M"


def test_avahi_byte_arrays_decode_into_a_mapping() -> None:
    assert decode_txt(_avahi_record(code="K7QP2M", room="Salon")) == {
        "code": "K7QP2M",
        "room": "Salon",
    }


def test_zeroconf_byte_mappings_decode_into_the_same_mapping() -> None:
    assert decode_txt({b"code": b"K7QP2M", b"room": b"Salon"}) == {
        "code": "K7QP2M",
        "room": "Salon",
    }


def test_a_record_that_is_not_utf8_is_skipped_rather_than_fatal() -> None:
    assert decode_txt([[0xFF, 0xFE], list(b"code=K7QP2M")]) == {"code": "K7QP2M"}


def test_no_record_at_all_decodes_to_nothing() -> None:
    assert decode_txt(None) == {}


def test_a_pair_without_a_separator_is_ignored() -> None:
    assert decode_txt([list(b"nonsense")]) == {}


# -- turning a record into a room --------------------------------------------


def test_a_record_without_a_code_is_not_a_room() -> None:
    assert room_from_txt({"room": "Salon", "host": "Filip"}) is None


def test_a_code_is_normalised_and_the_rest_is_trimmed() -> None:
    room = room_from_txt({"code": " k7qp2m ", "room": " Salon ", "host": " Filip "})
    assert room == DiscoveredRoom(code="K7QP2M", name="Salon", host="Filip")


def test_a_named_room_is_titled_by_its_name_and_subtitled_by_who_has_it() -> None:
    room = DiscoveredRoom(code="K7QP2M", name="Salon", host="Filip")
    assert room.title == "Salon"
    assert room.subtitle == "Filip · K7QP2M"


def test_an_unnamed_room_falls_back_to_its_code() -> None:
    room = DiscoveredRoom(code="K7QP2M", name="", host="")
    assert room.title == "Pokój K7QP2M"
    assert room.subtitle == "K7QP2M"


# -- what actually reaches the screen ----------------------------------------


def test_our_own_room_is_not_offered_back_to_us() -> None:
    rooms = [DiscoveredRoom("K7QP2M", "Salon", "Filip"), DiscoveredRoom("AB12CD", "Biuro", "Ala")]
    assert [room.code for room in visible_rooms(rooms, "k7qp2m")] == ["AB12CD"]


def test_one_room_announced_on_two_interfaces_is_shown_once() -> None:
    rooms = [
        DiscoveredRoom("AB12CD", "Biuro", "Ala"),
        DiscoveredRoom("AB12CD", "Biuro", "Ala"),
    ]
    assert len(visible_rooms(rooms)) == 1


def test_the_order_the_rooms_arrived_in_is_kept() -> None:
    rooms = [
        DiscoveredRoom("CC33DD", "Trzeci", ""),
        DiscoveredRoom("AA11BB", "Pierwszy", ""),
    ]
    assert [room.code for room in visible_rooms(rooms)] == ["CC33DD", "AA11BB"]


def test_no_room_of_our_own_leaves_every_discovery_visible() -> None:
    rooms = [DiscoveredRoom("AA11BB", "", ""), DiscoveredRoom("CC33DD", "", "")]
    assert len(visible_rooms(rooms, "")) == 2
