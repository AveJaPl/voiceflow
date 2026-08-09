"""Tests for the decoding-bias vocabulary: config parsing and prompt building."""

from __future__ import annotations

from voiceflow.config import parse_config
from voiceflow.transcriber import MAX_PROMPT_CHARS, build_initial_prompt


def test_empty_vocabulary_means_no_prompt() -> None:
    """None, not an empty string: Whisper treats "" as a real (useless) prompt."""
    assert build_initial_prompt(()) is None


def test_terms_are_joined_into_a_sentence() -> None:
    assert build_initial_prompt(("Supabase", "Coolify")) == "Supabase, Coolify."


def test_duplicates_are_dropped_case_insensitively() -> None:
    assert build_initial_prompt(("Supabase", "supabase", "Coolify")) == "Supabase, Coolify."


def test_first_spelling_wins() -> None:
    """Order follows the config so the user sees what they wrote."""
    assert build_initial_prompt(("PostgreSQL", "postgresql")) == "PostgreSQL."


def test_overlong_vocabulary_drops_whole_terms() -> None:
    """Never truncate mid-word: a fragment would bias towards a non-existent word."""
    terms = tuple(f"Termin{index:03d}" for index in range(200))

    prompt = build_initial_prompt(terms)

    assert prompt is not None
    assert len(prompt) <= MAX_PROMPT_CHARS + 1  # the trailing full stop
    assert "Termin" in prompt
    for chunk in prompt.rstrip(".").split(", "):
        assert chunk.startswith("Termin")
        assert len(chunk) == len("Termin000")


def test_config_reads_a_yaml_list() -> None:
    config = parse_config({"model": {"vocabulary": ["Supabase", "Coolify"]}})

    assert config.model.vocabulary == ("Supabase", "Coolify")


def test_config_defaults_to_no_vocabulary() -> None:
    assert parse_config({}).model.vocabulary == ()


def test_config_accepts_a_bare_string() -> None:
    """A single term written without brackets is a plausible mistake, not an error."""
    assert parse_config({"model": {"vocabulary": "Supabase"}}).model.vocabulary == ("Supabase",)


def test_config_skips_non_string_entries() -> None:
    config = parse_config({"model": {"vocabulary": ["Supabase", 42, None, "  ", "Coolify"]}})

    assert config.model.vocabulary == ("Supabase", "Coolify")


def test_config_survives_a_nonsense_value() -> None:
    assert parse_config({"model": {"vocabulary": {"a": 1}}}).model.vocabulary == ()


def test_terms_are_stripped() -> None:
    config = parse_config({"model": {"vocabulary": ["  Supabase  "]}})

    assert config.model.vocabulary == ("Supabase",)
