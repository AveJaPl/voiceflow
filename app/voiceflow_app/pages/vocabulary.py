"""Editable Whisper vocabulary presented as a five-column card grid."""

from __future__ import annotations

from collections.abc import Callable, Mapping
from typing import Any

import gi

gi.require_version("Gtk", "4.0")
from gi.repository import Gtk  # noqa: E402

from voiceflow_app import style
from voiceflow_app.pages.common import empty_state, label, page_content, page_header
from voiceflow_app.services import ensure_mutable_section, section, string_list_value


class VocabularyPage(Gtk.ScrolledWindow):
    """Manage proper names and domain terms passed to Whisper."""

    def __init__(self, on_dirty: Callable[[], None], on_toast: Callable[[str], None]) -> None:
        super().__init__(hscrollbar_policy=Gtk.PolicyType.NEVER)
        self.add_css_class("page-scroll")
        self._on_dirty = on_dirty
        self._on_toast = on_toast
        self._terms: list[str] = []

        content = page_content(self)
        content.append(
            page_header(
                "Słownik",
                "Dodaj nazwy własne i terminy, które Whisper ma rozpoznawać dokładniej.",
            )
        )

        add_card = Gtk.Box(
            orientation=Gtk.Orientation.HORIZONTAL,
            spacing=style.SPACE_12,
        )
        add_card.add_css_class("card")
        add_card.add_css_class("content-card")
        self.entry = Gtk.Entry(placeholder_text="Dodaj termin…")
        self.entry.add_css_class("flat-entry")
        self.entry.set_hexpand(True)
        self.entry.connect("activate", self._on_add)
        add_card.append(self.entry)
        add_button = Gtk.Button(label="Dodaj")
        add_button.add_css_class("primary-button")
        add_button.connect("clicked", self._on_add)
        add_card.append(add_button)
        content.append(add_card)

        terms_group = Gtk.Box(
            orientation=Gtk.Orientation.VERTICAL,
            spacing=style.SPACE_16,
        )
        self.counter = label("0 TERMINÓW", "section-label")
        terms_group.append(self.counter)
        self.terms_holder = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        terms_group.append(self.terms_holder)
        content.append(terms_group)
        self._render()

    def load_config(self, config: Mapping[str, Any]) -> None:
        """Replace the editor state from a raw configuration mapping."""
        self._terms = string_list_value(section(config, "model"), "vocabulary", [])
        self.entry.set_text("")
        self._render()

    def apply_to_config(self, config: dict[str, Any]) -> None:
        """Overlay the vocabulary while preserving unknown model keys."""
        ensure_mutable_section(config, "model")["vocabulary"] = list(self._terms)

    def _on_add(self, _widget: Gtk.Widget) -> None:
        term = self.entry.get_text().strip()
        if not term:
            return
        if term.casefold() in {item.casefold() for item in self._terms}:
            self._on_toast("Ten termin jest już w słowniku")
            return
        self._terms.append(term)
        self.entry.set_text("")
        self._render()
        self._on_dirty()

    def _remove(self, term: str) -> None:
        self._terms.remove(term)
        self._render()
        self._on_dirty()

    def _render(self) -> None:
        while child := self.terms_holder.get_first_child():
            self.terms_holder.remove(child)
        count = len(self._terms)
        self.counter.set_label("1 TERMIN" if count == 1 else f"{count} TERMINÓW")
        if not self._terms:
            self.terms_holder.append(
                empty_state(
                    "accessories-dictionary-symbolic",
                    "Słownik jest pusty. Dodaj pierwszy termin w polu powyżej.",
                )
            )
            return

        flow = Gtk.FlowBox(
            selection_mode=Gtk.SelectionMode.NONE,
            row_spacing=style.SPACE_8,
            column_spacing=style.SPACE_8,
            homogeneous=True,
        )
        flow.add_css_class("vocabulary-grid")
        flow.set_halign(Gtk.Align.FILL)
        flow.set_valign(Gtk.Align.START)
        flow.set_min_children_per_line(5)
        flow.set_max_children_per_line(5)
        for term in self._terms:
            tile = Gtk.Overlay()
            tile.add_css_class("vocabulary-tile")
            term_label = label(term, "vocabulary-term")
            term_label.set_halign(Gtk.Align.FILL)
            term_label.set_valign(Gtk.Align.CENTER)
            term_label.set_justify(Gtk.Justification.CENTER)
            term_label.set_wrap(True)
            tile.set_child(term_label)
            remove_button = Gtk.Button(icon_name="window-close-symbolic")
            remove_button.add_css_class("vocabulary-remove")
            remove_button.set_halign(Gtk.Align.END)
            remove_button.set_valign(Gtk.Align.START)
            remove_button.set_tooltip_text(f"Usuń termin {term}")
            remove_button.connect(
                "clicked", lambda _button, current=term: self._remove(current)
            )
            tile.add_overlay(remove_button)
            flow.append(tile)
        self.terms_holder.append(flow)
