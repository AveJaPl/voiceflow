"""Choosing which player to show. No D-Bus, no subprocess."""

from __future__ import annotations

from voiceflow.nowplaying import Candidate, candidate_from, choose, unwrap


def _candidate(bus_name: str, **overrides) -> Candidate:
    base = dict(
        bus_name=bus_name,
        status="Playing",
        title="Smells Like Teen Spirit",
        artist="Nirvana",
        player="Spotify",
        art_url="https://i.scdn.co/image/abc",
    )
    base.update(overrides)
    return Candidate(**base)  # type: ignore[arg-type]


def test_nothing_playing_means_no_tile():
    assert choose([]) is None
    assert choose([_candidate("org.mpris.MediaPlayer2.spotify", status="Paused")]) is None


def test_playing_without_a_title_is_not_something_to_show():
    """Pusty tytuł to nie jest „co gra" — to odtwarzacz, który nic nie mówi."""
    assert choose([_candidate("org.mpris.MediaPlayer2.x", title="")]) is None


def test_the_only_player_wins():
    track = choose([_candidate("org.mpris.MediaPlayer2.spotify")])

    assert track is not None
    assert track.title == "Smells Like Teen Spirit"
    assert track.artist == "Nirvana"
    assert track.player == "Spotify"


def test_bluetooth_proxy_loses_to_the_real_application():
    """Głośnik po AVRCP wisi obok aplikacji i zwykle nie podaje okładki.

    Sprawdzone na maszynie Filipa: JBL_Clip_5 nie wystawia metadanych w ogóle.
    Tu bierzemy wariant trudniejszy — proxy, które jednak coś podaje.
    """
    track = choose(
        [
            _candidate("org.mpris.MediaPlayer2.JBL_Clip_5", art_url="", player="JBL"),
            _candidate("org.mpris.MediaPlayer2.spotify"),
        ]
    )

    assert track is not None
    assert track.player == "Spotify"


def test_tie_is_broken_repeatably_by_bus_name():
    """Bez tego wybór skakałby między odtwarzaczami przy każdym odczycie."""
    track = choose(
        [
            _candidate("org.mpris.MediaPlayer2.zzz", player="Zzz"),
            _candidate("org.mpris.MediaPlayer2.aaa", player="Aaa"),
        ]
    )

    assert track is not None
    assert track.player == "Aaa"


def test_player_without_art_still_shows_when_it_is_the_only_one():
    track = choose([_candidate("org.mpris.MediaPlayer2.mpv", art_url="", player="mpv")])

    assert track is not None
    assert track.art_url == ""


# --- składanie kandydata z surowych odczytów -------------------------------


def test_artists_are_joined_into_one_line():
    candidate = candidate_from(
        "org.mpris.MediaPlayer2.spotify",
        {"xesam:title": "Numb", "xesam:artist": ["Linkin Park", "Jay-Z"]},
        "Playing",
        "Spotify",
    )

    assert candidate.artist == "Linkin Park, Jay-Z"


def test_missing_identity_falls_back_to_the_bus_name():
    candidate = candidate_from(
        "org.mpris.MediaPlayer2.mpv", {"xesam:title": "coś"}, "Playing", None
    )

    assert candidate.player == "mpv"


def test_garbage_metadata_does_not_crash_the_read():
    """Metadane przychodzą z cudzej aplikacji — nie mamy na nie wpływu."""
    candidate = candidate_from("org.mpris.MediaPlayer2.x", "to nie jest mapa", "Playing", "X")

    assert candidate.title == ""
    assert candidate.playing is False


# --- rozpakowanie odpowiedzi busctl ----------------------------------------


def test_busctl_wrappers_are_stripped_at_every_depth():
    document = {
        "type": "a{sv}",
        "data": {
            "xesam:title": {"type": "s", "data": "Numb"},
            "xesam:artist": {"type": "as", "data": ["Linkin Park"]},
        },
    }

    assert unwrap(document) == {"xesam:title": "Numb", "xesam:artist": ["Linkin Park"]}


def test_plain_values_survive_unwrapping():
    assert unwrap({"type": "s", "data": "Paused"}) == "Paused"
    assert unwrap(["a", "b"]) == ["a", "b"]
    assert unwrap(7) == 7
