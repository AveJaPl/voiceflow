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

Protocol, one JSON object per line:
    {"state": "listening", "text": "..."}   pulsing dot, live text
    {"state": "transcribing"}               dimmed steady dot
    {"state": "error", "text": "..."}       square marker, message stays put
    {"state": "hide"}                       quit
End of stdin also quits, so the overlay can never outlive its daemon.
"""

from __future__ import annotations

import json
import sys
import threading

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

    # -- placement ---------------------------------------------------------

    def reposition(self) -> None:
        """Anchor the card at the bottom centre of the primary monitor.

        Its size is fixed, so this only has to run once per show, but repeating it
        costs nothing and survives a monitor layout change mid-dictation.
        """
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
        if name in ("transcribing", "error"):
            context.add_class(name)

    # -- protocol ----------------------------------------------------------

    def apply(self, message: dict[str, object]) -> bool:
        """Apply one protocol message. Returns False when the overlay should quit."""
        state = str(message.get("state", ""))
        raw_text = message.get("text")
        text = raw_text if isinstance(raw_text, str) and raw_text.strip() else None

        if state == "hide":
            return False

        if state != self._state:
            self._state = state
            self._set_dot_state(state)
            if state == "listening" and text is None:
                self.message.set_text("Słucham…")
                self._set_muted(True)
            elif state == "transcribing":
                self.message.set_text("Przetwarzam…")
                self._set_muted(True)
            elif state == "error":
                self._set_muted(False)

        if text is not None:
            self.message.set_text(text)
            self._set_muted(False)

        if not self.window.get_visible():
            self.window.show_all()
        self.reposition()
        return True


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
