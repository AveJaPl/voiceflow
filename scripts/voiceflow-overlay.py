#!/usr/bin/env python3
"""On-screen dictation indicator, driven by newline-delimited JSON on stdin.

Runs as a separate process on the *system* Python because it needs PyGObject,
which the project's uv virtualenv deliberately does not carry.

Why an X11 override-redirect window instead of a normal Wayland one: on GNOME a
client cannot refuse keyboard focus, and a focused overlay would swallow the
paste that ends every dictation. It also cannot choose its own position, so a
plain window lands dead centre over the user's work. An override-redirect X11
window (GTK's POPUP type, via XWayland) is outside the window manager's control:
no focus, no decorations, and self-chosen placement. Verified on GNOME 50.

On the look: monochrome and matte on purpose. There is no real backdrop blur to
be had — GTK3 has no equivalent of backdrop-filter and Wayland will not let a
window see what is behind it — so this leans on translucency, a hairline edge and
an inset top highlight instead of faking a shine it cannot earn.

Widget names all carry a ``vf`` prefix. Do not name a widget ``text``: GTK3 uses
``text`` as an internal CSS node name and the ID selector silently loses, which
drops the label back to the theme's accent colour.

The card can be dragged with the left mouse button and remembers where it was
put. Position lives in its own state file rather than in config.yaml: dragging
rewrites it constantly, and config.yaml is a hand-written commented document
that a machine has no business rewriting. Double-click returns it to the
default spot, which is the only way back once it has been dragged somewhere
unhelpful.

Protocol, one JSON object per line:
    {"state": "listening", "text": "..."}   pulsing dot, live text
    {"state": "transcribing"}               dimmed steady dot
    {"state": "notice", "text": "..."}      one-line card, closes itself
    {"state": "error", "text": "..."}       square marker, message stays put
    {"state": "hide"}                       quit
End of stdin also quits, so the overlay can never outlive its daemon.

``notice`` carries an optional ``timeout_ms`` and exists so that outcomes like
"nothing was said" can be reported in the same place the user is already
looking, instead of a desktop notification that lands in a different corner of
the screen and outlives its usefulness.
"""

from __future__ import annotations

import json
import os
import sys
import threading
from pathlib import Path

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, GLib, Gtk, Pango  # noqa: E402

#: The card has no drop shadow, and therefore no transparent margin around it.
#: A shadow needs padding to fall into, and Mutter does not composite this
#: override-redirect window's alpha the way GTK assumes: the faded edge showed up
#: on screen as a grey rectangle even though the rendered pixels were transparent.
#: Removing the shadow removes the entire failure mode instead of tuning it.
CARD_WIDTH = 828
BOTTOM_MARGIN = 90
#: Diameter of the status dot, in pixels.
DOT_SIZE = 8
#: The message area is locked to this many lines so the card never changes height.
MAX_LINES = 5
#: Caps the label's requested width so text wraps instead of stretching the card.
#: Keep roughly proportional to CARD_WIDTH, or the card grows past its own width.
MAX_WIDTH_CHARS = 69
#: Height reserved per line of message text, in pixels.
LINE_HEIGHT = 24
#: Vertical padding inside the card.
CARD_PADDING_Y = 18
#: How long a self-closing ``notice`` stays on screen, in milliseconds.
NOTICE_TIMEOUT_MS = 2400
#: How much of the card must stay on a monitor for a saved position to be
#: honoured. A laptop undocked from an external screen would otherwise restore
#: the card onto coordinates that no longer exist, and it would simply vanish.
MIN_VISIBLE_PX = 80


def position_file() -> Path:
    """Where the dragged position is remembered.

    Resolved by hand rather than imported from ``voiceflow.paths``: this script
    runs on the system interpreter, which cannot see the project's virtualenv.
    Keep in step with ``paths.data_dir()``.
    """
    base = os.environ.get("XDG_DATA_HOME") or os.path.join(Path.home(), ".local", "share")
    return Path(base) / "voiceflow" / "overlay-position.json"


def load_position() -> tuple[int, int] | None:
    """Read the remembered position, or None when unset or unreadable."""
    try:
        data = json.loads(position_file().read_text(encoding="utf-8"))
        return int(data["x"]), int(data["y"])
    except (OSError, ValueError, TypeError, KeyError):
        return None


def save_position(x: int, y: int) -> None:
    """Persist the position. Best-effort: a failure here must not break dictation."""
    path = position_file()
    try:
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        path.write_text(json.dumps({"x": int(x), "y": int(y)}), encoding="utf-8")
    except OSError as exc:
        print(f"nie można zapisać pozycji okna: {exc}", file=sys.stderr, flush=True)


def clear_position() -> None:
    """Forget the dragged position so the default placement applies again."""
    try:
        position_file().unlink(missing_ok=True)
    except OSError as exc:
        print(f"nie można usunąć pozycji okna: {exc}", file=sys.stderr, flush=True)

#: Kept as str, not bytes: a bytes literal cannot hold the non-ASCII characters
#: that show up in these comments, and it fails at import time if one slips in.
CSS = """
/* The window must not paint anything of its own; the card covers it entirely. */
window {
  background-color: transparent;
  background-image: none;
}

/* Matte, not glossy. Nearly opaque with a restrained radius: a big radius plus a
   wide glow is the house style of every generic "glass" widget, and it is what
   made this look templated. */
#vfCard {
  background-color: rgba(15, 15, 17, 0.94);
  border: 1px solid rgba(255, 255, 255, 0.12);
  border-radius: 10px;
  /* Inset only. An outer shadow would need transparent padding around the card,
     which is exactly what rendered as a grey rectangle on screen. The highlight
     on the top edge carries the sense of thickness on its own. */
  box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.08);
}

/* A real circle, not a font glyph: glyph size and baseline drift between fonts,
   and this has to line up with the first line of text exactly. Monochrome
   throughout — state is carried by brightness and motion, never by hue. */
#vfDot {
  background-color: rgba(255, 255, 255, 0.95);
  border-radius: 50%;
  animation-name: vfBreathe;
  animation-duration: 1.8s;
  animation-iteration-count: infinite;
  animation-timing-function: ease-in-out;
}
#vfDot.transcribing {
  background-color: rgba(255, 255, 255, 0.34);
  animation-name: none;
}
#vfDot.error {
  background-color: rgba(255, 255, 255, 0.95);
  border-radius: 2px;
  animation-name: none;
}

@keyframes vfBreathe {
  0%   { opacity: 1.0; }
  50%  { opacity: 0.22; }
  100% { opacity: 1.0; }
}

#vfMessage {
  font-family: "SF Pro Text", "Inter", "Cantarell", "Ubuntu", sans-serif;
  font-size: 17px;
  color: rgba(255, 255, 255, 0.95);
}
#vfMessage.muted {
  color: rgba(255, 255, 255, 0.42);
}
"""


class Overlay:
    """A borderless always-on-top indicator that never takes focus."""

    def __init__(self) -> None:
        self.window = Gtk.Window(type=Gtk.WindowType.POPUP)
        self.window.set_keep_above(True)
        self.window.set_accept_focus(False)
        self.window.set_focus_on_map(False)
        self.window.set_skip_taskbar_hint(True)
        self.window.set_skip_pager_hint(True)
        self.window.set_app_paintable(True)
        self.window.set_resizable(False)

        screen = Gdk.Screen.get_default()
        visual = screen.get_rgba_visual()
        if visual is not None:
            # Without an RGBA visual the rounded corners render as black wedges.
            self.window.set_visual(visual)

        settings = Gtk.Settings.get_default()
        if settings is not None:
            # Ubuntu defaults to subpixel (RGB) antialiasing, which assumes an
            # opaque surface it can borrow neighbouring channels from. On a
            # translucent window that assumption does not hold, so greyscale
            # antialiasing is the safer choice for text over alpha.
            settings.set_property("gtk-xft-rgba", "none")

        provider = Gtk.CssProvider()
        provider.load_from_data(CSS.encode("utf-8"))
        Gtk.StyleContext.add_provider_for_screen(
            screen, provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        )

        card = Gtk.EventBox()
        card.set_name("vfCard")
        card.set_size_request(CARD_WIDTH, -1)
        # An EventBox has its own input window, so the card — not the toplevel —
        # is what the pointer actually talks to. Motion is requested only while
        # button 1 is held: plain pointer motion would wake this handler for
        # every mouse move across the screen, for nothing.
        card.add_events(
            Gdk.EventMask.BUTTON_PRESS_MASK
            | Gdk.EventMask.BUTTON_RELEASE_MASK
            | Gdk.EventMask.BUTTON1_MOTION_MASK
        )
        card.connect("button-press-event", self._on_button_press)
        card.connect("button-release-event", self._on_button_release)
        card.connect("motion-notify-event", self._on_motion)
        self.card = card

        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=13)
        row.set_margin_top(CARD_PADDING_Y)
        row.set_margin_bottom(CARD_PADDING_Y)
        row.set_margin_start(20)
        row.set_margin_end(20)

        self.dot = Gtk.Box()
        self.dot.set_name("vfDot")
        self.dot.set_size_request(DOT_SIZE, DOT_SIZE)
        # Top-aligned, not centred: with two or three lines of text a centred dot
        # drifts away from the first line and stops reading as a status light.
        self.dot.set_valign(Gtk.Align.START)
        self.dot.set_halign(Gtk.Align.CENTER)
        self.dot.set_margin_top(6)
        row.pack_start(self.dot, False, False, 0)

        self.message = Gtk.Label(label="Słucham…")
        self.message.set_name("vfMessage")
        self.message.set_xalign(0.0)
        self.message.set_line_wrap(True)
        self.message.set_line_wrap_mode(Pango.WrapMode.WORD_CHAR)
        self.message.set_lines(MAX_LINES)
        self.message.set_ellipsize(Pango.EllipsizeMode.END)
        # set_size_request on the card is a MINIMUM, not a maximum, so long text
        # widened the card to whatever it needed instead of wrapping. Capping the
        # label's width in characters is what actually forces the wrap.
        self.message.set_max_width_chars(MAX_WIDTH_CHARS)
        # Reserve both lines up front and top-align the text. Otherwise the card
        # changes height between one and two lines and the whole thing jumps around
        # the screen while you are still talking.
        self.message.set_size_request(-1, MAX_LINES * LINE_HEIGHT)
        self.message.set_valign(Gtk.Align.START)
        self.message.set_yalign(0.0)
        row.pack_start(self.message, True, True, 0)

        card.add(row)
        self.window.add(card)

        self._state = ""
        self._muted = False
        self._set_muted(True)
        #: Pointer offset inside the card while a drag is in progress.
        self._drag_offset: tuple[float, float] | None = None
        #: GLib source id of a pending self-close, when a notice is showing.
        self._notice_timer: int | None = None
        self._position = load_position()
        self.window.connect("realize", self._on_realize)

    # -- dragging ----------------------------------------------------------

    def _on_realize(self, _widget: Gtk.Widget) -> None:
        self._set_cursor("grab")

    def _set_cursor(self, name: str) -> None:
        """Signal that the card is draggable. Silently skipped if unsupported."""
        window = self.window.get_window()
        display = Gdk.Display.get_default()
        if window is None or display is None:
            return
        cursor = Gdk.Cursor.new_from_name(display, name)
        if cursor is not None:
            window.set_cursor(cursor)

    def _on_button_press(self, _widget: Gtk.Widget, event: Gdk.EventButton) -> bool:
        if event.button != 1:
            return False
        if event.type == Gdk.EventType.DOUBLE_BUTTON_PRESS:
            # The way back. Once the card has been parked somewhere unhelpful
            # there is otherwise no route to the default position short of
            # deleting a file by hand.
            self._drag_offset = None
            self._position = None
            clear_position()
            self.reposition()
            return True
        x, y = self.window.get_position()
        self._drag_offset = (event.x_root - x, event.y_root - y)
        self._set_cursor("grabbing")
        return True

    def _on_motion(self, _widget: Gtk.Widget, event: Gdk.EventMotion) -> bool:
        if self._drag_offset is None:
            return False
        offset_x, offset_y = self._drag_offset
        self._position = (int(event.x_root - offset_x), int(event.y_root - offset_y))
        self.window.move(*self._position)
        return True

    def _on_button_release(self, _widget: Gtk.Widget, event: Gdk.EventButton) -> bool:
        if event.button != 1 or self._drag_offset is None:
            return False
        self._drag_offset = None
        self._set_cursor("grab")
        if self._position is not None:
            # Persist only on release. Saving on every motion event would write
            # the file hundreds of times per drag.
            self._position = self._clamp(*self._position)
            self.window.move(*self._position)
            save_position(*self._position)
        return True

    # -- placement ---------------------------------------------------------

    def _clamp(self, x: int, y: int) -> tuple[int, int]:
        """Keep a usable strip of the card on some monitor."""
        display = Gdk.Display.get_default()
        if display is None:
            return x, y
        areas = [monitor.get_workarea() for monitor in self._monitors(display)]
        if not areas:
            return x, y
        width, _height = self.window.get_size()
        left = min(area.x for area in areas)
        top = min(area.y for area in areas)
        right = max(area.x + area.width for area in areas)
        bottom = max(area.y + area.height for area in areas)
        # The card may hang off the left/right edges as long as a grabbable
        # strip stays reachable; it may never go above the top, because there
        # would be nothing left to grab it by.
        x = max(left - width + MIN_VISIBLE_PX, min(x, right - MIN_VISIBLE_PX))
        y = max(top, min(y, bottom - MIN_VISIBLE_PX))
        return x, y

    @staticmethod
    def _monitors(display: Gdk.Display) -> list[Gdk.Monitor]:
        monitors = [display.get_monitor(i) for i in range(display.get_n_monitors())]
        return [m for m in monitors if m is not None]

    def _is_visible_somewhere(self, x: int, y: int) -> bool:
        display = Gdk.Display.get_default()
        if display is None:
            return False
        width, height = self.window.get_size()
        for monitor in self._monitors(display):
            area = monitor.get_workarea()
            overlap_x = min(x + width, area.x + area.width) - max(x, area.x)
            overlap_y = min(y + height, area.y + area.height) - max(y, area.y)
            if overlap_x >= MIN_VISIBLE_PX and overlap_y >= MIN_VISIBLE_PX:
                return True
        return False

    def reposition(self) -> None:
        """Place the card: where the user dragged it, else bottom centre.

        Repeated on every update so a monitor being unplugged mid-dictation
        cannot strand the card on coordinates that no longer exist.
        """
        if self._drag_offset is not None:
            # A drag is in progress; the pointer owns the position right now.
            return
        if self._position is not None and self._is_visible_somewhere(*self._position):
            self.window.move(*self._position)
            return
        display = Gdk.Display.get_default()
        if display is None:
            return
        monitor = display.get_primary_monitor() or display.get_monitor(0)
        if monitor is None:
            return
        area = monitor.get_workarea()
        width, height = self.window.get_size()
        x = area.x + (area.width - width) // 2
        y = area.y + area.height - height - BOTTOM_MARGIN
        self.window.move(x, y)

    # -- appearance --------------------------------------------------------

    def _set_muted(self, muted: bool) -> None:
        if muted == self._muted:
            return
        self._muted = muted
        context = self.message.get_style_context()
        if muted:
            context.add_class("muted")
        else:
            context.remove_class("muted")

    def _set_dot_state(self, name: str) -> None:
        context = self.dot.get_style_context()
        for value in ("transcribing", "error"):
            context.remove_class(value)
        if name == "notice":
            # A notice is an outcome, not a live state: the steady dimmed dot
            # says "finished, nothing to show" without any motion to catch the
            # eye of someone who has already moved on.
            context.add_class("transcribing")
        elif name in ("transcribing", "error"):
            context.add_class(name)

    def _set_compact(self, compact: bool) -> None:
        """Shrink the card to a single line, or restore the full message area.

        The tall card exists so live text does not make it jump around while
        you speak. A notice has no live text, so that reason is gone and the
        reserved empty space just reads as a bug.
        """
        lines = 1 if compact else MAX_LINES
        self.message.set_lines(lines)
        self.message.set_size_request(-1, lines * LINE_HEIGHT)

    # -- protocol ----------------------------------------------------------

    def apply(self, message: dict[str, object]) -> bool:
        """Apply one protocol message. Returns False when the overlay should quit."""
        state = str(message.get("state", ""))
        raw_text = message.get("text")
        text = raw_text if isinstance(raw_text, str) and raw_text.strip() else None

        if state == "hide":
            return False

        # Any new message supersedes a pending self-close.
        self._cancel_notice_timer()

        if state != self._state:
            self._state = state
            self._set_dot_state(state)
            self._set_compact(state == "notice")
            if state == "listening" and text is None:
                self.message.set_text("Słucham…")
                self._set_muted(True)
            elif state == "transcribing":
                self.message.set_text("Przetwarzam…")
                self._set_muted(True)
            elif state in ("error", "notice"):
                self._set_muted(False)

        if text is not None:
            self.message.set_text(text)
            self._set_muted(False)

        if not self.window.get_visible():
            self.window.show_all()
        self.reposition()

        if state == "notice":
            raw_timeout = message.get("timeout_ms")
            timeout = (
                int(raw_timeout)
                if isinstance(raw_timeout, (int, float)) and raw_timeout > 0
                else NOTICE_TIMEOUT_MS
            )
            self._notice_timer = GLib.timeout_add(timeout, self._on_notice_expired)
        return True

    def _cancel_notice_timer(self) -> None:
        if self._notice_timer is not None:
            GLib.source_remove(self._notice_timer)
            self._notice_timer = None

    def _on_notice_expired(self) -> bool:
        """Close the overlay once a notice has had its moment."""
        self._notice_timer = None
        Gtk.main_quit()
        return False


def main() -> int:
    overlay = Overlay()

    def on_line(raw: str) -> bool:
        raw = raw.strip()
        if not raw:
            return False
        try:
            message = json.loads(raw)
        except json.JSONDecodeError:
            print(f"nieprawidłowy JSON: {raw!r}", file=sys.stderr, flush=True)
            return False
        if not isinstance(message, dict):
            return False
        if not overlay.apply(message):
            Gtk.main_quit()
        return False

    def reader() -> None:
        # A thread rather than an IO watch: stdin is a plain pipe from the daemon
        # and blocking reads keep the parsing trivially correct.
        for line in sys.stdin:
            GLib.idle_add(on_line, line)
        GLib.idle_add(Gtk.main_quit)

    threading.Thread(target=reader, name="stdin-reader", daemon=True).start()
    Gtk.main()
    return 0


if __name__ == "__main__":
    sys.exit(main())
