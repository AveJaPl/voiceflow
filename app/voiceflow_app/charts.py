"""Cairo capability probe shared by every GTK drawing area."""

from __future__ import annotations

from typing import Any

import gi

gi.require_version("Gdk", "4.0")
gi.require_version("Gtk", "4.0")
from gi.repository import Gdk, Gtk  # noqa: E402

try:
    import cairo  # type: ignore[import-not-found]
except ImportError:
    cairo = None  # type: ignore[assignment]


UNAVAILABLE_MESSAGE = (
    "Wykresy wymagają pakietu python3-gi-cairo "
    "(sudo apt install python3-gi-cairo)"
)


def probe_cairo_support() -> bool:
    """Exercise both PyGObject's Cairo bridge and a DrawingArea callback.

    Importing :mod:`cairo` alone is not enough: ``python3-gi-cairo`` supplies
    the converter that turns GTK/GDK Cairo arguments into ``cairo.Context``.
    ``require_foreign`` checks that converter, while the tiny image-surface
    operation verifies that GDK accepts the resulting context.  Registering a
    draw function also catches an unusable DrawingArea API before pages render.
    """
    if cairo is None:
        return False
    try:
        gi.require_foreign("cairo")
        area = Gtk.DrawingArea()
        area.set_draw_func(lambda *_args: None)
        surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, 1, 1)
        context = cairo.Context(surface)
        color = Gdk.RGBA()
        color.parse("rgba(255,255,255,0.55)")
        Gdk.cairo_set_source_rgba(context, color)
        context.paint()
    except Exception:
        # This is a startup capability probe: any bridge failure must degrade
        # to the explanatory placeholder instead of breaking the application.
        return False
    return True


def unavailable_label() -> Gtk.Label:
    """Return the consistent in-place chart dependency explanation."""
    message = Gtk.Label(label=UNAVAILABLE_MESSAGE, wrap=True, xalign=0)
    message.add_css_class("chart-unavailable")
    return message


def context_type() -> Any:
    """Expose the optional module for drawing code without importing it twice."""
    return cairo
