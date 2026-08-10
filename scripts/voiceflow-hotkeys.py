#!/usr/bin/env python3
"""Global push-to-talk key, delivered through the XDG GlobalShortcuts portal.

NOT WIRED IN. Nothing launches this yet — push-to-talk is parked. It works up
to the point where the desktop asks the user to confirm the new shortcut, and
that one-time prompt is why the feature is on hold, not any defect here. Run it
by hand to try it:

    systemd-run --user --scope --quiet \\
        --unit=app-io.github.avejapl.voiceflow-test \\
        python3 scripts/voiceflow-hotkeys.py '<Control><Alt>space'

The systemd scope is not decoration: the portal refuses callers it cannot name
("An app id is required"), and an unsandboxed process is named by its unit.

Why this exists as a separate process, and why the portal at all:

GNOME's own shortcut system (the ``gsettings`` custom keybinding that runs
``voiceflow toggle``) reports only that a key was *pressed*. There is no release
event anywhere in that path, so push-to-talk — record while held — cannot be
built on it, at any price.

The obvious alternative, reading the keyboard directly through ``/dev/input``,
was rejected on purpose: ``scripts/install-system-deps.sh`` already refuses to
put the user in the ``input`` group because that grants read access to every
input device, which is a keylogger surface. Push-to-talk is not worth handing
voiceflow the ability to see every keystroke on the machine.

``org.freedesktop.portal.GlobalShortcuts`` emits both ``Activated`` and
``Deactivated``, needs no new permissions, and the compositor — not this
process — owns the key grab. voiceflow never sees a keystroke it was not
explicitly bound to. It runs on the system interpreter because the D-Bus
plumbing lives in PyGObject, which the project's uv virtualenv does not carry.

Usage:
    voiceflow-hotkeys.py '<Super>space'

Emits one JSON object per line on stdout, for the daemon to act on:
    {"event": "ready"}
    {"event": "pressed"}
    {"event": "released"}
Anything that goes wrong is a line on stderr and a non-zero exit; the daemon
treats that as "no push-to-talk" and keeps working.
"""

from __future__ import annotations

import json
import re
import sys

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gio, GLib  # noqa: E402

PORTAL_BUS = "org.freedesktop.portal.Desktop"
PORTAL_PATH = "/org/freedesktop/portal/desktop"
SHORTCUTS_IFACE = "org.freedesktop.portal.GlobalShortcuts"
REQUEST_IFACE = "org.freedesktop.portal.Request"
SESSION_IFACE = "org.freedesktop.portal.Session"

#: Our single shortcut's id within the portal session.
SHORTCUT_ID = "push_to_talk"

#: GNOME accelerator modifier -> portal modifier. The portal spec spells
#: modifiers in caps and joins them to the key with "+".
_MODIFIERS = {
    "super": "SUPER",
    # GNOME writes <Super>, but <Meta> turns up in hand-edited configs and in
    # bindings copied from other desktops. Same key, so accept both.
    "meta": "SUPER",
    "control": "CTRL",
    "ctrl": "CTRL",
    "primary": "CTRL",
    "alt": "ALT",
    "shift": "SHIFT",
}


def to_portal_trigger(accelerator: str) -> str:
    """Translate ``<Super>space`` into the portal's ``SUPER+space``.

    Accepts the GNOME accelerator syntax the rest of the project already uses,
    so one binding string can drive both the gsettings toggle and this.
    """
    modifiers = [m.lower() for m in re.findall(r"<([^>]+)>", accelerator)]
    key = re.sub(r"<[^>]+>", "", accelerator).strip()
    if not key:
        raise ValueError(f"skrót {accelerator!r} nie zawiera klawisza głównego")
    parts: list[str] = []
    for modifier in modifiers:
        portal = _MODIFIERS.get(modifier)
        if portal is None:
            raise ValueError(f"nieznany modyfikator skrótu: {modifier!r}")
        if portal not in parts:
            parts.append(portal)
    # Single letters are lowercase in the portal's syntax; named keys
    # (space, F9, ...) are passed through as written.
    parts.append(key.lower() if len(key) == 1 else key)
    return "+".join(parts)


def emit(event: str, **extra: object) -> None:
    """Write one protocol line. Flushed: the daemon reads this live."""
    print(json.dumps({"event": event, **extra}), flush=True)


class PortalShortcut:
    """Bind one shortcut and turn its press/release into stdout lines."""

    def __init__(self, trigger: str) -> None:
        self.trigger = trigger
        self.loop = GLib.MainLoop()
        self.connection = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        self.session_handle: str | None = None
        self._token = 0
        self._failure: str | None = None

    # -- portal request/response plumbing ----------------------------------

    def _unique_token(self, prefix: str) -> str:
        self._token += 1
        return f"voiceflow_{prefix}_{self._token}"

    def _request_path(self, token: str) -> str:
        """The object path the portal will answer on.

        The portal derives it from our bus name, and the spec tells clients to
        compute it and subscribe *before* issuing the call — otherwise a fast
        reply can land before the subscription exists and hang us forever.
        """
        sender = self.connection.get_unique_name()
        assert sender is not None
        sender = sender[1:].replace(".", "_")
        return f"/org/freedesktop/portal/desktop/request/{sender}/{token}"

    def _call_with_response(
        self, method: str, arguments: list[object], signature: str, prefix: str
    ) -> dict[str, object]:
        """Invoke a portal method and block until its Response signal arrives."""
        token = self._unique_token(prefix)
        path = self._request_path(token)
        result: dict[str, object] = {}
        loop = GLib.MainLoop()

        def on_response(_conn, _sender, _path, _iface, _signal, parameters):
            code, values = parameters.unpack()
            result["code"] = code
            result["values"] = values
            loop.quit()

        subscription = self.connection.signal_subscribe(
            PORTAL_BUS, REQUEST_IFACE, "Response", path, None,
            Gio.DBusSignalFlags.NONE, on_response,
        )
        try:
            options = {"handle_token": GLib.Variant("s", token)}
            if prefix == "session":
                options["session_handle_token"] = GLib.Variant(
                    "s", self._unique_token("shandle")
                )
            self.connection.call_sync(
                PORTAL_BUS, PORTAL_PATH, SHORTCUTS_IFACE, method,
                GLib.Variant(signature, (*arguments, options)),
                GLib.VariantType("(o)"), Gio.DBusCallFlags.NONE, -1, None,
            )
            # A portal request can sit waiting on a user-facing dialog, so there
            # is deliberately no timeout here.
            loop.run()
        finally:
            self.connection.signal_unsubscribe(subscription)

        if result.get("code") != 0:
            raise RuntimeError(
                f"portal odrzucił {method} (kod {result.get('code')}) — "
                "prawdopodobnie okno zgody zostało anulowane"
            )
        return dict(result.get("values") or {})

    # -- lifecycle ---------------------------------------------------------

    def create_session(self) -> None:
        values = self._call_with_response("CreateSession", [], "(a{sv})", "session")
        handle = values.get("session_handle")
        if not isinstance(handle, str):
            raise RuntimeError("portal nie zwrócił uchwytu sesji")
        self.session_handle = handle

    def bind(self) -> None:
        assert self.session_handle is not None
        shortcut = (
            SHORTCUT_ID,
            {
                "description": GLib.Variant("s", "voiceflow — dyktowanie (przytrzymaj)"),
                "preferred_trigger": GLib.Variant("s", self.trigger),
            },
        )
        # Plain Python values here, not GLib.Variant wrappers: the signature
        # already says what each argument is, and pre-wrapping makes the
        # construction fail. Only the a{sv} option values need explicit types.
        self._call_with_response(
            "BindShortcuts",
            [self.session_handle, [shortcut], ""],
            "(oa(sa{sv})sa{sv})",
            "bind",
        )

    def listen(self) -> None:
        def on_activated(_c, _s, _p, _i, signal, parameters):
            session, shortcut_id, _timestamp, _options = parameters.unpack()
            if session != self.session_handle or shortcut_id != SHORTCUT_ID:
                return
            emit("pressed" if signal == "Activated" else "released")

        for signal in ("Activated", "Deactivated"):
            self.connection.signal_subscribe(
                PORTAL_BUS, SHORTCUTS_IFACE, signal, PORTAL_PATH, None,
                Gio.DBusSignalFlags.NONE, on_activated,
            )

        def on_closed(*_args):
            # The compositor dropped our session (logout, portal restart).
            # Exiting lets the daemon notice and decide whether to respawn.
            self._failure = "portal zamknął sesję skrótów"
            self.loop.quit()

        self.connection.signal_subscribe(
            PORTAL_BUS, SESSION_IFACE, "Closed", self.session_handle, None,
            Gio.DBusSignalFlags.NONE, on_closed,
        )

        emit("ready", trigger=self.trigger)
        self.loop.run()
        if self._failure:
            raise RuntimeError(self._failure)


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(f"użycie: {argv[0]} '<Super>space'", file=sys.stderr)
        return 2
    try:
        trigger = to_portal_trigger(argv[1])
    except ValueError as exc:
        print(f"nieprawidłowy skrót: {exc}", file=sys.stderr)
        return 2
    def stage(message: str) -> None:
        # Progress goes to stderr, never stdout: stdout is the daemon's event
        # protocol and a stray line there would be parsed as an event.
        print(f"[push-to-talk] {message}", file=sys.stderr, flush=True)

    try:
        shortcut = PortalShortcut(trigger)
        stage("łączę z portalem…")
        shortcut.create_session()
        stage("sesja utworzona; wiążę skrót "
              f"{trigger} (pulpit może poprosić o zgodę — zaakceptuj okno)")
        shortcut.bind()
        stage("skrót związany; nasłuchuję")
        shortcut.listen()
    except KeyboardInterrupt:
        return 0
    except (GLib.Error, RuntimeError) as exc:
        print(f"push-to-talk niedostępne: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
