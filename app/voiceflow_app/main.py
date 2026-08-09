"""Application shell, sidebar navigation, and cross-page coordination."""

from __future__ import annotations

import copy
import threading
from collections.abc import Mapping
from typing import Any

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gio, GLib, Gtk  # noqa: E402

from voiceflow_app import __version__, charts, services, style
from voiceflow_app.pages.dashboard import DashboardPage
from voiceflow_app.pages.history import HistoryPage
from voiceflow_app.pages.settings import SettingsPage
from voiceflow_app.pages.stats import StatsPage
from voiceflow_app.pages.vocabulary import VocabularyPage


APPLICATION_ID = "io.github.avejapl.voiceflow"
STATUS_INTERVAL_SECONDS = 2
HISTORY_INTERVAL_SECONDS = 5


class VoiceflowWindow(Adw.ApplicationWindow):
    """Premium local-first window containing navigation and all app pages."""

    __gtype_name__ = "VoiceflowWindow"

    def __init__(
        self, application: Adw.Application, *, cairo_available: bool
    ) -> None:
        super().__init__(application=application, title="voiceflow")
        self.set_default_size(style.WINDOW_WIDTH, style.WINDOW_HEIGHT)
        self.set_size_request(style.WINDOW_MIN_WIDTH, style.WINDOW_MIN_HEIGHT)
        self.add_css_class("voiceflow-window")

        self._raw_config: dict[str, Any] = {}
        self._dirty = False
        self._service_operation = False
        self._status_source_id = 0
        self._history_source_id = 0
        self._current_page = "dashboard"
        self._pages: dict[str, Gtk.Widget] = {}

        self.toast_overlay = Adw.ToastOverlay()
        self.set_content(self.toast_overlay)
        self.window_root = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        self.window_root.add_css_class("voiceflow-root")
        self.toast_overlay.set_child(self.window_root)

        try:
            self._raw_config = services.load_raw_config()
        except RuntimeError as exc:
            self._build_error_shell(str(exc))
            return

        self._cairo_available = cairo_available
        self._build_pages()
        self._build_shell()
        self._load_editors()
        self._refresh_history()
        self._refresh_status()
        self._status_source_id = GLib.timeout_add_seconds(
            STATUS_INTERVAL_SECONDS, self._refresh_status
        )
        self._history_source_id = GLib.timeout_add_seconds(
            HISTORY_INTERVAL_SECONDS, self._refresh_visible_history
        )

    def _build_pages(self) -> None:
        self.dashboard = DashboardPage(
            self._toggle_dictation,
            self._service_action,
            self._copy_text,
            cairo_available=self._cairo_available,
        )
        self.history = HistoryPage(self._copy_text, self._delete_history_record)
        self.stats = StatsPage(cairo_available=self._cairo_available)
        self.vocabulary = VocabularyPage(self._set_dirty, self._toast)
        self.settings = SettingsPage(self._set_dirty, self._toast)
        self._pages = {
            "dashboard": self.dashboard,
            "history": self.history,
            "stats": self.stats,
            "vocabulary": self.vocabulary,
            "settings": self.settings,
        }

    def _build_shell(self) -> None:
        self.stack = Gtk.Stack(transition_type=Gtk.StackTransitionType.CROSSFADE)
        self.stack.set_transition_duration(style.REVEAL_MS)
        self.stack.set_hexpand(True)
        self.stack.set_vexpand(True)
        for name, page in self._pages.items():
            self.stack.add_named(page, name)
        self.stack.set_visible_child_name("dashboard")

        content_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        content_box.append(self.stack)
        self._build_dirty_bar(content_box)

        toolbar = Adw.ToolbarView()
        header = Adw.HeaderBar(show_title=False, show_start_title_buttons=False)
        header.add_css_class("content-header")
        header.add_css_class("flat")
        # Page title lives IN the window bar (left; window buttons sit right),
        # reclaiming ~50 px of vertical space the in-content title used to burn.
        self.header_title = Gtk.Label(label="Przegląd")
        self.header_title.add_css_class("header-page-title")
        self.header_title.set_xalign(0.0)
        header.pack_start(self.header_title)
        toolbar.add_top_bar(header)
        toolbar.set_content(content_box)
        toolbar.set_hexpand(True)
        toolbar.set_vexpand(True)
        self.window_root.append(self._build_sidebar())
        self.window_root.append(toolbar)

    def _build_sidebar(self) -> Gtk.Widget:
        sidebar = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        sidebar.add_css_class("sidebar")
        sidebar.set_size_request(style.SIDEBAR_WIDTH, -1)
        sidebar.set_hexpand(False)

        brand = Gtk.Box(
            orientation=Gtk.Orientation.HORIZONTAL,
            spacing=style.SPACE_12,
        )
        brand.add_css_class("brand-row")
        brand.append(self._build_brand_wave())
        name = Gtk.Label(label="voiceflow", xalign=0)
        name.add_css_class("brand-name")
        brand.append(name)
        sidebar.append(brand)

        self.nav_list = Gtk.ListBox(selection_mode=Gtk.SelectionMode.SINGLE)
        self.nav_list.add_css_class("sidebar-list")
        self.nav_list.set_hexpand(True)
        navigation = (
            ("dashboard", "audio-input-microphone-symbolic", "Przegląd"),
            ("history", "document-open-recent-symbolic", "Historia"),
            ("stats", "view-grid-symbolic", "Statystyki"),
            ("vocabulary", "accessories-dictionary-symbolic", "Słownik"),
            ("settings", "emblem-system-symbolic", "Ustawienia"),
        )
        first_row: Gtk.ListBoxRow | None = None
        for page_name, icon_name, label_text in navigation:
            row = Gtk.ListBoxRow(name=page_name)
            overlay = Gtk.Overlay()
            content = Gtk.Box(
                orientation=Gtk.Orientation.HORIZONTAL,
                spacing=style.SPACE_12,
            )
            content.add_css_class("nav-content")
            nav_icon = Gtk.Image.new_from_icon_name(icon_name)
            nav_icon.add_css_class("nav-icon")
            content.append(nav_icon)
            label = Gtk.Label(label=label_text, xalign=0)
            label.add_css_class("nav-label")
            content.append(label)
            overlay.set_child(content)
            indicator = Gtk.Box()
            indicator.add_css_class("nav-indicator")
            indicator.set_halign(Gtk.Align.START)
            indicator.set_valign(Gtk.Align.CENTER)
            overlay.add_overlay(indicator)
            row.set_child(overlay)
            self.nav_list.append(row)
            first_row = first_row or row
        self.nav_list.connect("row-selected", self._on_navigation)
        sidebar.append(self.nav_list)

        spacer = Gtk.Box()
        spacer.set_vexpand(True)
        sidebar.append(spacer)

        footer = Gtk.Box(
            orientation=Gtk.Orientation.VERTICAL,
            spacing=style.SPACE_8,
        )
        footer.add_css_class("sidebar-footer")
        status_row = Gtk.Box(
            orientation=Gtk.Orientation.HORIZONTAL,
            spacing=style.SPACE_8,
        )
        self.sidebar_dot = Gtk.Label(label="●")
        self.sidebar_dot.add_css_class("status-dot")
        status_row.append(self.sidebar_dot)
        self.sidebar_status = Gtk.Label(label="Sprawdzanie…", xalign=0)
        self.sidebar_status.add_css_class("daemon-footer-label")
        status_row.append(self.sidebar_status)
        footer.append(status_row)
        version = Gtk.Label(label=f"v{__version__}", xalign=0)
        version.add_css_class("version-label")
        footer.append(version)
        sidebar.append(footer)
        if first_row is not None:
            self.nav_list.select_row(first_row)
        return sidebar

    @staticmethod
    def _build_brand_wave() -> Gtk.Widget:
        wave = Gtk.Box(
            orientation=Gtk.Orientation.HORIZONTAL,
            spacing=style.SPACE_4,
        )
        wave.add_css_class("brand-wave")
        wave.set_valign(Gtk.Align.CENTER)
        for size_class in ("brand-wave-short", "brand-wave-tall", "brand-wave-short"):
            bar = Gtk.Box()
            bar.add_css_class("brand-wave-bar")
            bar.add_css_class(size_class)
            bar.set_valign(Gtk.Align.CENTER)
            wave.append(bar)
        return wave

    def _build_dirty_bar(self, content: Gtk.Box) -> None:
        self.dirty_revealer = Gtk.Revealer(
            transition_type=Gtk.RevealerTransitionType.SLIDE_UP,
            transition_duration=style.REVEAL_MS,
        )
        self.dirty_revealer.set_halign(Gtk.Align.FILL)
        self.dirty_revealer.set_visible(False)
        bar = Gtk.Box(
            orientation=Gtk.Orientation.HORIZONTAL,
            spacing=style.SPACE_8,
        )
        bar.add_css_class("dirty-bar")
        label = Gtk.Label(label="Niezapisane zmiany", xalign=0)
        label.add_css_class("dirty-label")
        label.set_hexpand(True)
        bar.append(label)
        self.undo_button = Gtk.Button(label="Cofnij")
        self.undo_button.add_css_class("secondary-button")
        self.undo_button.connect("clicked", self._on_undo)
        bar.append(self.undo_button)
        self.apply_button = Gtk.Button(label="Zastosuj")
        self.apply_button.add_css_class("primary-button")
        self.apply_button.connect("clicked", self._on_apply)
        bar.append(self.apply_button)
        self.dirty_revealer.set_child(bar)
        content.append(self.dirty_revealer)

    def _build_error_shell(self, message: str) -> None:
        """Show a focused malformed-config error without constructing editors."""
        error = Gtk.Box(
            orientation=Gtk.Orientation.VERTICAL,
            spacing=style.SPACE_12,
        )
        error.set_halign(Gtk.Align.CENTER)
        error.set_valign(Gtk.Align.CENTER)
        error.set_hexpand(True)
        error.add_css_class("error-page")
        icon = Gtk.Image.new_from_icon_name("dialog-error-symbolic")
        icon.add_css_class("error-icon")
        error.append(icon)
        title = Gtk.Label(label="Nie można wczytać konfiguracji")
        title.add_css_class("error-title")
        error.append(title)
        detail = Gtk.Label(
            label=f"{message}\n\nPopraw plik konfiguracyjny i uruchom aplikację ponownie.",
            justify=Gtk.Justification.CENTER,
            wrap=True,
            max_width_chars=64,
        )
        detail.add_css_class("muted")
        error.append(detail)
        sidebar = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        sidebar.add_css_class("sidebar")
        sidebar.set_size_request(style.SIDEBAR_WIDTH, -1)
        brand = Gtk.Box(
            orientation=Gtk.Orientation.HORIZONTAL,
            spacing=style.SPACE_12,
        )
        brand.add_css_class("brand-row")
        brand.append(self._build_brand_wave())
        name = Gtk.Label(label="voiceflow")
        name.add_css_class("brand-name")
        brand.append(name)
        sidebar.append(brand)
        self.window_root.append(sidebar)
        self.window_root.append(error)

    def _on_navigation(
        self, _list_box: Gtk.ListBox, row: Gtk.ListBoxRow | None
    ) -> None:
        if row is None or not hasattr(self, "stack"):
            return
        page_name = row.get_name()
        if page_name not in self._pages:
            return
        self._current_page = page_name
        titles = {
            "dashboard": "Przegląd",
            "history": "Historia",
            "stats": "Statystyki",
            "vocabulary": "Słownik",
            "settings": "Ustawienia",
        }
        self.header_title.set_label(titles.get(page_name, "voiceflow"))
        self.stack.set_visible_child_name(page_name)
        self.dirty_revealer.set_visible(
            self._dirty and page_name in {"vocabulary", "settings"}
        )
        if page_name in {"dashboard", "history", "stats"}:
            self._refresh_history()
        if page_name == "settings":
            self.settings.refresh_runtime_status()

    def _load_editors(self) -> None:
        self.vocabulary.load_config(self._raw_config)
        self.settings.load_config(self._raw_config)

    def _set_dirty(self) -> None:
        if self._dirty:
            return
        self._dirty = True
        self.dirty_revealer.set_visible(
            self._current_page in {"vocabulary", "settings"}
        )
        self.dirty_revealer.set_reveal_child(True)

    def _on_undo(self, _button: Gtk.Button) -> None:
        if self._service_operation:
            return
        try:
            self._raw_config = services.load_raw_config()
        except RuntimeError as exc:
            self._toast(str(exc))
            return
        self._load_editors()
        self._dirty = False
        self.dirty_revealer.set_reveal_child(False)
        self._toast("Przywrócono zapisane ustawienia")

    def _on_apply(self, _button: Gtk.Button) -> None:
        if not self._dirty or self._service_operation:
            return
        data = copy.deepcopy(self._raw_config)
        self.vocabulary.apply_to_config(data)
        self.settings.apply_to_config(data)
        self._service_operation = True
        self.stack.set_sensitive(False)
        self.undo_button.set_sensitive(False)
        self.apply_button.set_sensitive(False)

        def worker() -> None:
            try:
                services.atomic_write_config(data)
                services.run_systemctl("restart")
            except (OSError, RuntimeError, ValueError) as exc:
                GLib.idle_add(self._finish_apply, False, str(exc), data)
                return
            GLib.idle_add(self._finish_apply, True, "", data)

        threading.Thread(target=worker, name="config-apply", daemon=True).start()

    def _finish_apply(self, success: bool, detail: str, data: dict[str, Any]) -> bool:
        self._service_operation = False
        self.stack.set_sensitive(True)
        self.undo_button.set_sensitive(True)
        self.apply_button.set_sensitive(True)
        if success:
            self._raw_config = data
            self._dirty = False
            self.dirty_revealer.set_reveal_child(False)
            self._toast("Zastosowano — demon uruchamia się ponownie")
        else:
            self._toast(f"Nie udało się zastosować zmian: {detail}")
        self._refresh_status()
        return GLib.SOURCE_REMOVE

    def _toggle_dictation(self) -> None:
        try:
            response = services.send_request("toggle", timeout=0.5)
        except RuntimeError as exc:
            self._toast(str(exc))
            self._refresh_status()
            return
        message = response.get("message")
        if isinstance(message, str):
            self._toast(message)
        self._refresh_status()

    def _service_action(self) -> None:
        if self._service_operation:
            return
        action = "stop" if self.dashboard.daemon_online else "start"
        self._service_operation = True
        self.dashboard.set_service_busy(True)

        def worker() -> None:
            try:
                services.run_systemctl(action)
            except (OSError, RuntimeError, ValueError) as exc:
                GLib.idle_add(self._finish_service_action, False, action, str(exc))
                return
            GLib.idle_add(self._finish_service_action, True, action, "")

        threading.Thread(target=worker, name=f"daemon-{action}", daemon=True).start()

    def _finish_service_action(
        self, success: bool, action: str, detail: str
    ) -> bool:
        self._service_operation = False
        self.dashboard.set_service_busy(False)
        if success:
            message = (
                "Demon został zatrzymany" if action == "stop" else "Demon jest uruchamiany"
            )
            self._toast(message)
        else:
            self._toast(f"Nie udało się sterować demonem: {detail}")
        self._refresh_status()
        return GLib.SOURCE_REMOVE

    def _copy_text(self, text: str) -> None:
        def worker() -> None:
            try:
                services.copy_to_clipboard(text)
            except (OSError, RuntimeError) as exc:
                GLib.idle_add(self._toast, f"Nie udało się skopiować: {exc}")
                return
            GLib.idle_add(self._toast, "Skopiowano — wklej Ctrl+Shift+V")

        threading.Thread(target=worker, name="clipboard-copy", daemon=True).start()

    def _delete_history_record(self, record: services.HistoryRecord) -> None:
        try:
            deleted = services.delete_history_record(record)
        except OSError as exc:
            self._toast(f"Nie udało się usunąć wpisu: {exc}")
            return
        if not deleted:
            self._toast("Wpisu nie ma już w historii")
        else:
            self._toast("Usunięto wpis z historii")
        self._refresh_history()

    def _refresh_status(self) -> bool:
        try:
            response: Mapping[str, Any] | None = services.send_request("status")
        except RuntimeError:
            response = None
        self.dashboard.set_status(response)
        for css_class in ("ready", "offline"):
            self.sidebar_dot.remove_css_class(css_class)
        if response is None:
            self.sidebar_dot.add_css_class("offline")
            self.sidebar_status.set_label("Demon nieaktywny")
        else:
            self.sidebar_dot.add_css_class("ready")
            self.sidebar_status.set_label("Demon aktywny")
        return GLib.SOURCE_CONTINUE

    def _refresh_history(self) -> None:
        records = services.read_history_records()
        self.dashboard.update_history(records)
        self.history.update_history(records)
        self.stats.update_history(records)

    def _refresh_visible_history(self) -> bool:
        if self._current_page in {"dashboard", "history", "stats"}:
            self._refresh_history()
        return GLib.SOURCE_CONTINUE

    def _toast(self, message: str) -> bool:
        self.toast_overlay.add_toast(Adw.Toast.new(message))
        return GLib.SOURCE_REMOVE

    def do_unrealize(self) -> None:
        if self._status_source_id:
            GLib.source_remove(self._status_source_id)
            self._status_source_id = 0
        if self._history_source_id:
            GLib.source_remove(self._history_source_id)
            self._history_source_id = 0
        super().do_unrealize()


class VoiceflowApplication(Adw.Application):
    """Single-instance native application."""

    __gtype_name__ = "VoiceflowApplication"

    def __init__(self) -> None:
        super().__init__(
            application_id=APPLICATION_ID,
            flags=Gio.ApplicationFlags.DEFAULT_FLAGS,
        )

    def do_activate(self) -> None:
        Adw.StyleManager.get_default().set_color_scheme(Adw.ColorScheme.FORCE_DARK)
        style.install()
        window = self.get_active_window()
        if window is None:
            window = VoiceflowWindow(
                self, cairo_available=charts.probe_cairo_support()
            )
        window.present()


def main() -> int:
    """Run the voiceflow desktop application."""
    Adw.init()
    return VoiceflowApplication().run(None)
