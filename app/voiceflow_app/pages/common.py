"""Small native-page building blocks shared across the application."""

from __future__ import annotations

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gtk  # noqa: E402

from voiceflow_app import style


def label(text: str, *classes: str) -> Gtk.Label:
    """Create a left-aligned label with semantic CSS classes."""
    widget = Gtk.Label(label=text, xalign=0)
    for css_class in classes:
        widget.add_css_class(css_class)
    return widget


def page_content(scroller: Gtk.ScrolledWindow) -> Gtk.Box:
    """Attach a consistently padded, comfortably wide page to a scroller."""
    clamp = Adw.Clamp(
        maximum_size=style.PAGE_MAX_WIDTH,
        tightening_threshold=style.PAGE_TIGHTENING_WIDTH,
    )
    clamp.add_css_class("page-clamp")
    scroller.set_child(clamp)
    content = Gtk.Box(
        orientation=Gtk.Orientation.VERTICAL,
        spacing=style.SPACE_32,
    )
    content.add_css_class("page-content")
    clamp.set_child(content)
    return content


def page_header(title: str, description: str) -> Gtk.Box:
    """Build the in-content page intro.

    The page TITLE lives in the window header bar (set by the navigation
    handler), so only the one-sentence description renders here — the title
    parameter is kept for call-site readability.
    """
    del title  # shown in the header bar, not in the content
    heading = Gtk.Box(
        orientation=Gtk.Orientation.VERTICAL,
        spacing=style.SPACE_4,
    )
    subtitle = label(description, "page-subtitle")
    subtitle.set_wrap(True)
    heading.append(subtitle)
    return heading


def empty_state(icon_name: str, message: str) -> Gtk.Box:
    """Build a compact, centered empty state without oversized whitespace."""
    state = Gtk.Box(
        orientation=Gtk.Orientation.VERTICAL,
        spacing=style.SPACE_12,
    )
    state.add_css_class("card")
    state.add_css_class("empty-state")
    state.set_halign(Gtk.Align.FILL)
    state.set_valign(Gtk.Align.START)

    icon = Gtk.Image.new_from_icon_name(icon_name)
    icon.add_css_class("empty-icon")
    icon.set_halign(Gtk.Align.CENTER)
    state.append(icon)

    message_label = label(message, "empty-message")
    message_label.set_halign(Gtk.Align.CENTER)
    message_label.set_justify(Gtk.Justification.CENTER)
    message_label.set_wrap(True)
    state.append(message_label)
    return state
