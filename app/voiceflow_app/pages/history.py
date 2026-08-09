"""Searchable, expandable, local-only dictation history page."""

from __future__ import annotations

from collections.abc import Callable
from datetime import date, timedelta

import gi

gi.require_version("Gtk", "4.0")
from gi.repository import Gtk, Pango  # noqa: E402

from voiceflow_app import statlib, style
from voiceflow_app.pages.common import empty_state, label, page_content, page_header
from voiceflow_app.services import HistoryRecord


def _day_title(day: date) -> str:
    today = date.today()
    if day == today:
        return "DZISIAJ"
    if day == today - timedelta(days=1):
        return "WCZORAJ"
    return day.strftime("%d.%m.%Y")


def _time_title(timestamp: str) -> str:
    return statlib.local_datetime(timestamp).strftime("%H:%M")


def _record_key(record: HistoryRecord) -> str:
    return "\x1f".join(
        (
            str(record.get("timestamp", "")),
            str(record.get("words", 0)),
            str(record.get("chars", 0)),
            str(record.get("text") or ""),
        )
    )


class HistoryPage(Gtk.ScrolledWindow):
    """Render the newest two hundred records grouped by day."""

    def __init__(
        self,
        on_copy: Callable[[str], None],
        on_delete: Callable[[HistoryRecord], None],
    ) -> None:
        super().__init__(hscrollbar_policy=Gtk.PolicyType.NEVER)
        self.add_css_class("page-scroll")
        self._on_copy = on_copy
        self._on_delete = on_delete
        self._records: list[HistoryRecord] = []
        self._expanded: set[str] = set()

        content = page_content(self)
        content.append(
            page_header(
                "Historia",
                "Wyszukuj, rozwijaj i ponownie kopiuj lokalne dyktowania.",
            )
        )

        self.search = Gtk.SearchEntry(placeholder_text="Szukaj w historii…")
        self.search.add_css_class("search-entry")
        self.search.connect("search-changed", self._on_search_changed)
        content.append(self.search)

        self.list_box = Gtk.Box(
            orientation=Gtk.Orientation.VERTICAL,
            spacing=style.SPACE_32,
        )
        content.append(self.list_box)
        self._render()

    def update_history(self, records: list[HistoryRecord]) -> None:
        """Replace current records with the newest-first view source."""
        self._records = list(reversed(records[-200:]))
        available = {_record_key(record) for record in self._records}
        self._expanded.intersection_update(available)
        self._render()

    def _on_search_changed(self, _entry: Gtk.SearchEntry) -> None:
        self._render()

    def _render(self) -> None:
        while child := self.list_box.get_first_child():
            self.list_box.remove(child)
        query = self.search.get_text().strip().casefold()
        visible = [
            record
            for record in self._records
            if not query or query in str(record.get("text") or "").casefold()
        ]
        if not visible:
            message = (
                "Brak wyników. Spróbuj innego wyszukiwania."
                if query
                else "Historia jest pusta. Zakończone dyktowania pojawią się tutaj."
            )
            self.list_box.append(empty_state("document-open-recent-symbolic", message))
            return

        grouped: dict[date, list[HistoryRecord]] = {}
        for record in visible:
            grouped.setdefault(statlib.record_date(record), []).append(record)
        for day, records in grouped.items():
            group = Gtk.Box(
                orientation=Gtk.Orientation.VERTICAL,
                spacing=style.SPACE_16,
            )
            group.append(label(_day_title(day), "section-label"))
            for record in records:
                group.append(self._record_card(record))
            self.list_box.append(group)

    def _record_card(self, record: HistoryRecord) -> Gtk.Widget:
        key = _record_key(record)
        expanded = key in self._expanded
        card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        card.add_css_class("card")
        card.add_css_class("history-card")

        summary_button = Gtk.Button()
        summary_button.add_css_class("history-toggle")
        summary_button.set_tooltip_text(
            "Zwiń szczegóły wpisu" if expanded else "Rozwiń szczegóły wpisu"
        )
        summary = Gtk.Box(
            orientation=Gtk.Orientation.HORIZONTAL,
            spacing=style.SPACE_16,
        )
        body = Gtk.Box(
            orientation=Gtk.Orientation.VERTICAL,
            spacing=style.SPACE_8,
        )
        body.set_hexpand(True)
        timestamp = str(record["timestamp"])
        body.append(
            label(
                f"{_time_title(timestamp)} · {record.get('words', 0)} słów",
                "history-meta",
            )
        )
        text = record.get("text")
        content = text if isinstance(text, str) and text else "(treść nie była zapisywana)"
        preview = label(content, "history-preview")
        preview.set_wrap(True)
        preview.set_wrap_mode(Pango.WrapMode.WORD_CHAR)
        preview.set_lines(2)
        preview.set_ellipsize(Pango.EllipsizeMode.END)
        body.append(preview)
        summary.append(body)

        chevron = Gtk.Image.new_from_icon_name("go-next-symbolic")
        chevron.add_css_class("history-chevron")
        if expanded:
            chevron.add_css_class("expanded")
        chevron.set_valign(Gtk.Align.CENTER)
        summary.append(chevron)
        summary_button.set_child(summary)
        card.append(summary_button)

        revealer = Gtk.Revealer(
            transition_type=Gtk.RevealerTransitionType.SLIDE_DOWN,
            transition_duration=style.REVEAL_MS,
            reveal_child=expanded,
        )
        detail = Gtk.Box(
            orientation=Gtk.Orientation.VERTICAL,
            spacing=style.SPACE_16,
        )
        detail.add_css_class("history-detail")
        full_text = label(content, "history-full-text")
        full_text.set_wrap(True)
        full_text.set_wrap_mode(Pango.WrapMode.WORD_CHAR)
        detail.append(full_text)

        actions = Gtk.Box(
            orientation=Gtk.Orientation.HORIZONTAL,
            spacing=style.SPACE_8,
        )
        if isinstance(text, str) and text:
            copy_button = Gtk.Button(label="Kopiuj")
            copy_button.add_css_class("secondary-button")
            copy_button.connect("clicked", lambda _button, text=text: self._on_copy(text))
            actions.append(copy_button)

        delete_button = Gtk.Button(label="Usuń wpis")
        delete_button.add_css_class("destructive-button")
        actions.append(delete_button)
        detail.append(actions)
        revealer.set_child(detail)
        card.append(revealer)

        confirming = False

        def toggle(_button: Gtk.Button) -> None:
            nonlocal confirming
            will_expand = not revealer.get_reveal_child()
            revealer.set_reveal_child(will_expand)
            summary_button.set_tooltip_text(
                "Zwiń szczegóły wpisu" if will_expand else "Rozwiń szczegóły wpisu"
            )
            if will_expand:
                self._expanded.add(key)
                chevron.add_css_class("expanded")
            else:
                self._expanded.discard(key)
                chevron.remove_css_class("expanded")
                confirming = False
                delete_button.set_label("Usuń wpis")
                delete_button.remove_css_class("confirming")

        def delete(_button: Gtk.Button) -> None:
            nonlocal confirming
            if not confirming:
                confirming = True
                delete_button.set_label("Potwierdź usunięcie")
                delete_button.add_css_class("confirming")
                return
            self._expanded.discard(key)
            self._on_delete(record)

        summary_button.connect("clicked", toggle)
        delete_button.connect("clicked", delete)
        return card
