"""Reading, checking and writing the dictation shortcut in GNOME's own store.

The dictation key is not voiceflow's to keep: on GNOME it lives in gsettings as
a custom keybinding that runs ``voiceflow toggle``, which is why the desktop's
own Settings can see it and why nothing ever prompts for permission. This module
is the app's side of that arrangement — read the current key, find out what else
would answer to a candidate key, and write the new one.

The conflict check is the reason this file exists. GNOME ships something like a
hundred and seventy bound combinations, and a new binding does not replace them:
both fire, or the desktop wins and voiceflow silently never runs. Warning before
the fact is the only way a user finds out cheaply.

Comparison is deliberately structural, never textual. GNOME writes modifiers in
whatever order it pleases — ``<Shift><Super>space`` and ``<Super><Shift>space``
are the same key to the desktop and must be the same key here. Comparing the
strings makes an audit that looks thorough and quietly misses collisions.

Gio is imported lazily inside the functions that need it so the pure comparison
logic can be tested without a session bus or a display.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

#: Where install-hotkey.sh puts voiceflow's own custom keybinding.
VOICEFLOW_PATH = "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/voiceflow/"
MEDIA_KEYS_SCHEMA = "org.gnome.settings-daemon.plugins.media-keys"
CUSTOM_SCHEMA = "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding"

#: Schemas holding shortcuts that a dictation key could collide with.
SCANNED_SCHEMAS: tuple[str, ...] = (
    "org.gnome.desktop.wm.keybindings",
    "org.gnome.settings-daemon.plugins.media-keys",
    "org.gnome.shell.keybindings",
    "org.gnome.mutter.keybindings",
    "org.gnome.mutter.wayland.keybindings",
)

#: Human labels for the schemas above, so a warning reads like a sentence
#: rather than like a dconf path.
_SCHEMA_LABELS = {
    "org.gnome.desktop.wm.keybindings": "Okna",
    "org.gnome.settings-daemon.plugins.media-keys": "Skróty systemowe",
    "org.gnome.shell.keybindings": "GNOME Shell",
    "org.gnome.mutter.keybindings": "Mutter",
    "org.gnome.mutter.wayland.keybindings": "Mutter (Wayland)",
}

#: Different spellings of the same physical modifier. GNOME uses <Primary> for
#: Control in some schemas and <Control> in others.
_MODIFIER_ALIASES = {
    "primary": "control",
    "ctrl": "control",
    "meta": "super",
    "mod4": "super",
}

_MODIFIER_PATTERN = re.compile(r"<([^>]+)>")


@dataclass(frozen=True, slots=True)
class Binding:
    """One shortcut already claimed somewhere in the desktop."""

    accelerator: str
    owner: str
    #: True for voiceflow's own binding, which is being replaced rather than
    #: collided with and must never be reported as a conflict.
    is_voiceflow: bool = False


def normalize(accelerator: str) -> tuple[frozenset[str], str]:
    """Reduce an accelerator to (modifiers, key), ignoring order and case."""
    modifiers = frozenset(
        _MODIFIER_ALIASES.get(name.lower(), name.lower())
        for name in _MODIFIER_PATTERN.findall(accelerator)
    )
    key = _MODIFIER_PATTERN.sub("", accelerator).strip().lower()
    return modifiers, key


def is_complete(accelerator: str) -> bool:
    """True when the accelerator carries an actual key, not just modifiers."""
    return bool(normalize(accelerator)[1])


def conflicts(accelerator: str, bindings: list[Binding]) -> list[Binding]:
    """Everything other than voiceflow that already answers to this key."""
    if not is_complete(accelerator):
        return []
    target = normalize(accelerator)
    return [
        binding
        for binding in bindings
        if not binding.is_voiceflow and normalize(binding.accelerator) == target
    ]


def describe(found: list[Binding]) -> str:
    """One human sentence naming what a key is already used for."""
    names = []
    for binding in found:
        if binding.owner not in names:
            names.append(binding.owner)
    if len(names) == 1:
        return names[0]
    return ", ".join(names[:-1]) + " oraz " + names[-1]


def _pretty_action(key: str) -> str:
    """Turn a gsettings key like ``move-to-workspace-left`` into prose."""
    return key.replace("-static", "").replace("-", " ").strip().capitalize()


def scan() -> list[Binding]:
    """Collect every shortcut the desktop currently answers to."""
    from gi.repository import Gio

    source = Gio.SettingsSchemaSource.get_default()
    found: list[Binding] = []
    if source is None:
        return found

    for schema_name in SCANNED_SCHEMAS:
        schema = source.lookup(schema_name, True)
        if schema is None:
            continue
        settings = Gio.Settings.new(schema_name)
        label = _SCHEMA_LABELS.get(schema_name, schema_name)
        for key in schema.list_keys():
            value = settings.get_value(key)
            type_string = value.get_type_string()
            # Shortcut keys are either one accelerator or a list of them;
            # everything else in these schemas is unrelated configuration.
            if type_string == "s":
                accelerators = [value.get_string()]
            elif type_string == "as":
                accelerators = list(value.unpack())
            else:
                continue
            for accelerator in accelerators:
                if accelerator and is_complete(accelerator):
                    found.append(Binding(accelerator, f"{label}: {_pretty_action(key)}"))

    found.extend(_scan_custom())
    return found


def _scan_custom() -> list[Binding]:
    from gi.repository import Gio

    media = Gio.Settings.new(MEDIA_KEYS_SCHEMA)
    result: list[Binding] = []
    for path in media.get_strv("custom-keybindings"):
        entry = Gio.Settings.new_with_path(CUSTOM_SCHEMA, path)
        accelerator = entry.get_string("binding")
        if not accelerator or not is_complete(accelerator):
            continue
        name = entry.get_string("name") or "skrót użytkownika"
        result.append(
            Binding(accelerator, f"Własny: {name}", is_voiceflow=path == VOICEFLOW_PATH)
        )
    return result


def current_binding() -> str:
    """The dictation key as GNOME currently has it, or "" when unbound."""
    from gi.repository import Gio

    media = Gio.Settings.new(MEDIA_KEYS_SCHEMA)
    if VOICEFLOW_PATH not in media.get_strv("custom-keybindings"):
        return ""
    entry = Gio.Settings.new_with_path(CUSTOM_SCHEMA, VOICEFLOW_PATH)
    return entry.get_string("binding")


def apply_binding(accelerator: str, command: str) -> None:
    """Write the dictation shortcut, registering the entry if it is missing.

    Registration matters on a machine where the hotkey installer never ran, or
    where the user removed the entry by hand: without the path in the list,
    writing the binding succeeds and GNOME ignores it.
    """
    from gi.repository import Gio

    if not is_complete(accelerator):
        raise ValueError(f"skrót {accelerator!r} nie zawiera klawisza głównego")
    media = Gio.Settings.new(MEDIA_KEYS_SCHEMA)
    paths = media.get_strv("custom-keybindings")
    if VOICEFLOW_PATH not in paths:
        media.set_strv("custom-keybindings", [*paths, VOICEFLOW_PATH])
    entry = Gio.Settings.new_with_path(CUSTOM_SCHEMA, VOICEFLOW_PATH)
    entry.set_string("name", "voiceflow — dyktowanie")
    entry.set_string("command", command)
    entry.set_string("binding", accelerator)
    Gio.Settings.sync()
