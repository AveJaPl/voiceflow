"""The voiceflow desktop window for Windows.

Linux has the GTK4/libadwaita application in ``app/``; PyGObject publishes no
Windows wheel, so this is its Qt counterpart — deliberately the same window,
not a Windows-flavoured reinterpretation of it. The shell below mirrors
``app/voiceflow_app/main.py`` one part at a time: the same seven pages behind
the same sidebar, the page title in the window bar, one shared unsaved-changes
bar, and the same two timers driving status and history.

It talks to the daemon over the same local control channel the command line
uses and edits the same ``config.yaml`` — the window is a front end, never a
second source of truth.
"""

from __future__ import annotations

import copy
import logging
import os
import sys
from collections.abc import Mapping
from typing import Any

from PySide6.QtCore import QTimer, Qt
from PySide6.QtGui import QDesktopServices, QIcon
from PySide6.QtWidgets import (
    QApplication,
    QHBoxLayout,
    QLabel,
    QMainWindow,
    QPushButton,
    QStackedWidget,
    QVBoxLayout,
    QWidget,
)

from voiceflow.gui import service, theme
from voiceflow.gui.pages.dashboard import DashboardPage
from voiceflow.gui.pages.history import HistoryPage
from voiceflow.gui.pages.room import RoomPage
from voiceflow.gui.pages.sessions import SessionsPage
from voiceflow.gui.pages.settings import SettingsPage
from voiceflow.gui.pages.stats import StatsPage
from voiceflow.gui.pages.vocabulary import VocabularyPage
from voiceflow.gui.widgets import (
    BackgroundCall,
    BrandWave,
    NavButton,
    StatusDot,
    hbox,
    icon_label,
    label,
    plain,
    vbox,
)
from voiceflow.updates import installed_version

LOGGER = logging.getLogger(__name__)

STATUS_INTERVAL_MS = 2000
HISTORY_INTERVAL_MS = 5000
TOAST_MS = 3200

#: Page key, icon, sidebar label, header-bar title. One tuple so the three can
#: never drift apart.
NAVIGATION = (
    ("dashboard", "audio-input-microphone-symbolic", "Przegląd", "Przegląd"),
    ("history", "document-open-recent-symbolic", "Historia", "Historia"),
    ("stats", "view-grid-symbolic", "Statystyki", "Statystyki"),
    ("room", "system-users-symbolic", "Pokój", "Pokój"),
    ("sessions", "document-open-recent-symbolic", "Sesje", "Sesje"),
    ("vocabulary", "accessories-dictionary-symbolic", "Słownik", "Słownik"),
    ("settings", "emblem-system-symbolic", "Ustawienia", "Ustawienia"),
)

#: Only these two pages own configuration, so only they raise the dirty bar.
EDITOR_PAGES = {"vocabulary", "settings"}
#: These three read the history file.
HISTORY_PAGES = {"dashboard", "history", "stats"}


class MainWindow(QMainWindow):
    """Premium local-first window containing navigation and all app pages."""

    def __init__(self) -> None:
        super().__init__()
        self.setWindowTitle("voiceflow")
        self.resize(theme.WINDOW_WIDTH, theme.WINDOW_HEIGHT)
        self.setMinimumSize(theme.WINDOW_MIN_WIDTH, theme.WINDOW_MIN_HEIGHT)

        self._raw_config: dict[str, Any] = {}
        self._dirty = False
        self._service_operation = False
        self._status_pending = False
        self._current_page = "dashboard"
        self._pages: dict[str, QWidget] = {}
        self._nav_buttons: dict[str, NavButton] = {}

        self._root = QWidget()
        self._root.setObjectName("page-host")
        self._root_layout = QHBoxLayout(self._root)
        self._root_layout.setContentsMargins(0, 0, 0, 0)
        self._root_layout.setSpacing(0)
        self.setCentralWidget(self._root)

        try:
            self._raw_config = service.load_raw_config()
        except RuntimeError as exc:
            self._build_error_shell(str(exc))
            return

        self._build_pages()
        self._build_shell()
        self._build_toast()
        self._load_editors()
        self._refresh_history()
        self._refresh_status()

        self._status_timer = QTimer(self)
        self._status_timer.setInterval(STATUS_INTERVAL_MS)
        self._status_timer.timeout.connect(self._refresh_status)
        self._status_timer.start()

        self._history_timer = QTimer(self)
        self._history_timer.setInterval(HISTORY_INTERVAL_MS)
        self._history_timer.timeout.connect(self._refresh_visible_history)
        self._history_timer.start()

        self._check_update()

    # -- construction --------------------------------------------------------

    def _build_pages(self) -> None:
        self.dashboard = DashboardPage(
            self._toggle_dictation, self._service_action, self._copy_text
        )
        self.history = HistoryPage(self._copy_text, self._delete_history_record)
        self.stats = StatsPage()
        self.room = RoomPage(self.toast)
        self.sessions = SessionsPage(self.toast)
        self.vocabulary = VocabularyPage(self._set_dirty, self.toast)
        self.settings = SettingsPage(self._set_dirty, self.toast)
        self._pages = {
            "dashboard": self.dashboard,
            "history": self.history,
            "stats": self.stats,
            "room": self.room,
            "sessions": self.sessions,
            "vocabulary": self.vocabulary,
            "settings": self.settings,
        }

    def _build_shell(self) -> None:
        self._stack = QStackedWidget()
        for page in self._pages.values():
            self._stack.addWidget(page)
        self._stack.setCurrentWidget(self.dashboard)

        content = QWidget()
        content.setObjectName("plain")
        layout = QVBoxLayout(content)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(0)
        layout.addWidget(self._build_header())
        layout.addWidget(self._stack, 1)
        layout.addWidget(self._build_dirty_bar())

        self._root_layout.addWidget(self._build_sidebar())
        self._root_layout.addWidget(content, 1)

    def _build_header(self) -> QWidget:
        header = QWidget()
        header.setObjectName("content-header")
        header.setFixedHeight(48)
        layout = QHBoxLayout(header)
        layout.setContentsMargins(theme.SPACE_20, 0, theme.SPACE_16, 0)
        # The page title lives in the window bar, reclaiming the ~50 px of
        # vertical space an in-content title used to burn.
        self.header_title = label("Przegląd", "header-page-title")
        layout.addWidget(self.header_title)
        layout.addStretch(1)
        return header

    def _build_sidebar(self) -> QWidget:
        sidebar = QWidget()
        sidebar.setObjectName("sidebar")
        sidebar.setFixedWidth(theme.SIDEBAR_WIDTH)
        layout = QVBoxLayout(sidebar)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(0)

        brand = plain(hbox(theme.SPACE_12))
        brand.layout().setContentsMargins(theme.SPACE_20, theme.SPACE_20, theme.SPACE_16, theme.SPACE_16)
        brand.layout().addWidget(BrandWave())
        brand.layout().addWidget(label("voiceflow", "brand-name"))
        brand.layout().addStretch(1)
        layout.addWidget(brand)

        nav = plain(vbox(2))
        nav.layout().setContentsMargins(theme.SPACE_12, theme.SPACE_4, theme.SPACE_12, theme.SPACE_4)
        for key, icon_name, text, _title in NAVIGATION:
            button = NavButton(icon_name, text)
            button.clicked.connect(lambda _checked=False, name=key: self.show_page(name))
            self._nav_buttons[key] = button
            nav.layout().addWidget(button)
        self._nav_buttons["dashboard"].setChecked(True)
        layout.addWidget(nav)
        layout.addStretch(1)

        footer = plain(vbox(theme.SPACE_8))
        footer.layout().setContentsMargins(theme.SPACE_20, theme.SPACE_16, theme.SPACE_20, theme.SPACE_20)
        status_row = plain(hbox(theme.SPACE_8))
        self.sidebar_dot = StatusDot()
        self.sidebar_status = label("Sprawdzanie…", "daemon-footer-label")
        status_row.layout().addWidget(self.sidebar_dot)
        status_row.layout().addWidget(self.sidebar_status)
        status_row.layout().addStretch(1)
        footer.layout().addWidget(status_row)

        self.version_label = label(f"v{installed_version()}", "version-label")
        footer.layout().addWidget(self.version_label)

        # Hidden until the once-per-launch check finds a newer release.
        self.update_button = QPushButton("Dostępna aktualizacja")
        self.update_button.setObjectName("secondary-button")
        self.update_button.setVisible(False)
        footer.layout().addWidget(self.update_button)
        layout.addWidget(footer)
        return sidebar

    def _build_dirty_bar(self) -> QWidget:
        self.dirty_bar = QWidget()
        self.dirty_bar.setObjectName("plain")
        outer = QHBoxLayout(self.dirty_bar)
        outer.setContentsMargins(theme.SPACE_16, 0, theme.SPACE_16, theme.SPACE_16)

        bar = QWidget()
        bar.setObjectName("dirty-bar")
        layout = QHBoxLayout(bar)
        layout.setContentsMargins(theme.SPACE_16, theme.SPACE_12, theme.SPACE_16, theme.SPACE_12)
        layout.setSpacing(theme.SPACE_8)
        layout.addWidget(label("Niezapisane zmiany", "dirty-label"), 1)

        self.undo_button = QPushButton("Cofnij")
        self.undo_button.setObjectName("secondary-button")
        self.undo_button.clicked.connect(self._on_undo)
        layout.addWidget(self.undo_button)

        self.apply_button = QPushButton("Zastosuj")
        self.apply_button.setObjectName("primary-button")
        self.apply_button.clicked.connect(self._on_apply)
        layout.addWidget(self.apply_button)

        outer.addWidget(bar)
        self.dirty_bar.setVisible(False)
        return self.dirty_bar

    def _build_toast(self) -> None:
        """A floating message strip, the way Adw.ToastOverlay draws one."""
        self._toast_label = QLabel("", self._root)
        self._toast_label.setObjectName("toast")
        self._toast_label.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self._toast_label.hide()
        self._toast_timer = QTimer(self)
        self._toast_timer.setSingleShot(True)
        self._toast_timer.timeout.connect(self._toast_label.hide)

    def _build_error_shell(self, message: str) -> None:
        """Show a focused malformed-config error without constructing editors."""
        sidebar = QWidget()
        sidebar.setObjectName("sidebar")
        sidebar.setFixedWidth(theme.SIDEBAR_WIDTH)
        sidebar_layout = QVBoxLayout(sidebar)
        sidebar_layout.setContentsMargins(theme.SPACE_20, theme.SPACE_20, theme.SPACE_16, theme.SPACE_16)
        brand = plain(hbox(theme.SPACE_12))
        brand.layout().addWidget(BrandWave())
        brand.layout().addWidget(label("voiceflow", "brand-name"))
        brand.layout().addStretch(1)
        sidebar_layout.addWidget(brand)
        sidebar_layout.addStretch(1)

        error = plain(vbox(theme.SPACE_12))
        error.layout().setContentsMargins(theme.SPACE_48, theme.SPACE_48, theme.SPACE_48, theme.SPACE_48)
        error.layout().addStretch(1)
        glyph = icon_label("dialog-error-symbolic", 32, theme.TEXT_TERTIARY_SOLID)
        glyph.setAlignment(Qt.AlignmentFlag.AlignCenter)
        error.layout().addWidget(glyph, 0, Qt.AlignmentFlag.AlignHCenter)
        title = label("Nie można wczytać konfiguracji", "error-title")
        title.setAlignment(Qt.AlignmentFlag.AlignCenter)
        error.layout().addWidget(title)
        detail = label(
            f"{message}\n\nPopraw plik konfiguracyjny i uruchom aplikację ponownie.",
            "muted",
            wrap=True,
        )
        detail.setAlignment(Qt.AlignmentFlag.AlignCenter)
        error.layout().addWidget(detail)
        error.layout().addStretch(1)

        self._root_layout.addWidget(sidebar)
        self._root_layout.addWidget(error, 1)

    # -- navigation ----------------------------------------------------------

    def show_page(self, name: str) -> None:
        page = self._pages.get(name)
        if page is None:
            return
        self._current_page = name
        for key, button in self._nav_buttons.items():
            button.setChecked(key == name)
        title = next((entry[3] for entry in NAVIGATION if entry[0] == name), "voiceflow")
        self.header_title.setText(title)
        self._stack.setCurrentWidget(page)
        self.dirty_bar.setVisible(self._dirty and name in EDITOR_PAGES)
        if name in HISTORY_PAGES:
            self._refresh_history()
        if name == "room":
            self.room.refresh()
        if name == "sessions":
            self.sessions.refresh()
        if name == "settings":
            self.settings.refresh_runtime_status()

    # -- configuration -------------------------------------------------------

    def _load_editors(self) -> None:
        self.vocabulary.load_config(self._raw_config)
        self.settings.load_config(self._raw_config)

    def _set_dirty(self) -> None:
        if self._dirty:
            return
        self._dirty = True
        self.dirty_bar.setVisible(self._current_page in EDITOR_PAGES)

    def _on_undo(self) -> None:
        if self._service_operation:
            return
        try:
            self._raw_config = service.load_raw_config()
        except RuntimeError as exc:
            self.toast(str(exc))
            return
        self._load_editors()
        self._dirty = False
        self.dirty_bar.setVisible(False)
        self.toast("Przywrócono zapisane ustawienia")

    def _on_apply(self) -> None:
        if not self._dirty or self._service_operation:
            return
        data = copy.deepcopy(self._raw_config)
        self.vocabulary.apply_to_config(data)
        self.settings.apply_to_config(data)
        self._service_operation = True
        self._stack.setEnabled(False)
        self.undo_button.setEnabled(False)
        self.apply_button.setEnabled(False)

        def work() -> dict[str, Any]:
            service.atomic_write_config(data)
            # The daemon reads its configuration once, at startup, so a saved
            # setting that does not restart it is one that silently did not apply.
            if service.daemon_status() is not None:
                service.restart_daemon()
            return data

        BackgroundCall(
            work,
            lambda written: self._finish_apply(True, "", written),
            lambda message: self._finish_apply(False, message, data),
        )

    def _finish_apply(self, success: bool, detail: str, data: object) -> None:
        self._service_operation = False
        self._stack.setEnabled(True)
        self.undo_button.setEnabled(True)
        self.apply_button.setEnabled(True)
        if success and isinstance(data, dict):
            self._raw_config = data
            self._dirty = False
            self.dirty_bar.setVisible(False)
            self.toast("Zastosowano — demon uruchamia się ponownie")
        else:
            self.toast(f"Nie udało się zastosować zmian: {detail}")
        self._refresh_status()

    # -- daemon --------------------------------------------------------------

    def _toggle_dictation(self) -> None:
        def done(response: object) -> None:
            if isinstance(response, dict):
                message = response.get("message")
                if isinstance(message, str) and message:
                    self.toast(message)
            self._refresh_status()

        def failed(message: str) -> None:
            self.toast(message)
            self._refresh_status()

        BackgroundCall(lambda: service.daemon_command("toggle"), done, failed)

    def _service_action(self) -> None:
        if self._service_operation:
            return
        stopping = self.dashboard.daemon_online
        action = service.stop_daemon if stopping else service.start_daemon
        self._service_operation = True
        self.dashboard.set_service_busy(True)

        BackgroundCall(
            action,
            lambda _result: self._finish_service_action(True, stopping, ""),
            lambda message: self._finish_service_action(False, stopping, message),
        )

    def _finish_service_action(self, success: bool, stopping: bool, detail: str) -> None:
        self._service_operation = False
        self.dashboard.set_service_busy(False)
        if success:
            self.toast("Demon został zatrzymany" if stopping else "Demon jest uruchamiany")
        else:
            self.toast(f"Nie udało się sterować demonem: {detail}")
        self._refresh_status()

    def _refresh_status(self) -> None:
        # One status call in flight at a time: the socket timeout is longer
        # than the poll interval on a machine where the daemon is wedged.
        if self._status_pending:
            return
        self._status_pending = True
        BackgroundCall(service.daemon_status, self._apply_status, self._apply_status_error)

    def _apply_status_error(self, _message: str) -> None:
        self._apply_status(None)

    def _apply_status(self, response: object) -> None:
        self._status_pending = False
        status: Mapping[str, Any] | None = response if isinstance(response, dict) else None
        starting = status is None and service.launch_pending()
        self.dashboard.set_status(status, starting=starting)
        if status is None:
            self.sidebar_dot.set_colour(theme.TEXT_TERTIARY_SOLID)
            self.sidebar_status.setText("Demon się uruchamia" if starting else "Demon nieaktywny")
        else:
            self.sidebar_dot.set_colour(theme.TEXT_SECONDARY_SOLID)
            self.sidebar_status.setText("Demon aktywny")

    # -- history -------------------------------------------------------------

    def _refresh_history(self) -> None:
        BackgroundCall(service.history_records, self._apply_history)

    def _apply_history(self, records: object) -> None:
        if not isinstance(records, list):
            return
        self.dashboard.update_history(records)
        self.history.update_history(records)
        self.stats.update_history(records)

    def _refresh_visible_history(self) -> None:
        if self._current_page in HISTORY_PAGES:
            self._refresh_history()

    def _delete_history_record(self, record: Mapping[str, Any]) -> None:
        def done(deleted: object) -> None:
            self.toast("Usunięto wpis z historii" if deleted else "Wpisu nie ma już w historii")
            self._refresh_history()

        BackgroundCall(
            lambda: service.delete_history_record(record),
            done,
            lambda message: self.toast(f"Nie udało się usunąć wpisu: {message}"),
        )

    def _copy_text(self, text: str) -> None:
        try:
            service.copy_to_clipboard(text)
        except RuntimeError as exc:
            self.toast(f"Nie udało się skopiować: {exc}")
            return
        self.toast("Skopiowano — wklej Ctrl+V")

    # -- updates -------------------------------------------------------------

    def _check_update(self) -> None:
        """Once per launch; a newer release becomes a button in the footer."""
        BackgroundCall(service.newer_release, self._apply_update)

    def _apply_update(self, result: object) -> None:
        if not isinstance(result, tuple):
            self.version_label.setText(f"v{installed_version()} · aktualna")
            return
        latest, url = result
        self.version_label.setText(f"v{installed_version()} · dostępna aktualizacja")
        self.update_button.setText(f"Aktualizacja: {latest}")
        self.update_button.setToolTip(
            "Zobacz, co się zmieniło, i zaktualizuj tą samą komendą, którą instalowano voiceflow"
        )
        self.update_button.clicked.connect(lambda: QDesktopServices.openUrl(url))
        self.update_button.setVisible(True)

    # -- chrome --------------------------------------------------------------

    def toast(self, message: str) -> None:
        if not message:
            return
        self._toast_label.setText(message)
        self._toast_label.adjustSize()
        self._place_toast()
        self._toast_label.show()
        self._toast_label.raise_()
        self._toast_timer.start(TOAST_MS)

    def _place_toast(self) -> None:
        size = self._toast_label.sizeHint()
        self._toast_label.resize(size)
        self._toast_label.move(
            max(0, (self._root.width() - size.width()) // 2),
            max(0, self._root.height() - size.height() - theme.SPACE_24),
        )

    def resizeEvent(self, event) -> None:  # noqa: N802 - Qt naming
        super().resizeEvent(event)
        if getattr(self, "_toast_label", None) is not None and self._toast_label.isVisible():
            self._place_toast()

    def closeEvent(self, event) -> None:  # noqa: N802 - Qt naming
        # Closing the window must not take the daemon with it: dictation is the
        # product, this is only its control panel. The room advertisement does
        # go, though — a room nobody is watching must stop being announced.
        for timer_name in ("_status_timer", "_history_timer"):
            timer = getattr(self, timer_name, None)
            if timer is not None:
                timer.stop()
        room = getattr(self, "room", None)
        if room is not None:
            room.shutdown()
        BackgroundCall.drain()
        super().closeEvent(event)


def main(argv: list[str] | None = None) -> int:
    """Open the desktop window."""
    if os.name == "nt":
        # An installed copy can still be launched through a venv trampoline
        # that opens a console; the window must not appear behind one.
        from voiceflow.winplat.console import hide_own_console

        hide_own_console()
    logging.basicConfig(level=logging.WARNING)
    application = QApplication(argv if argv is not None else sys.argv)
    application.setApplicationName("voiceflow")
    application.setApplicationDisplayName("voiceflow")
    application.setStyle("Fusion")
    application.setStyleSheet(theme.STYLESHEET)
    # Quitting by any route — the window's close button, the taskbar, a session
    # logout — must not tear down a thread that is still working.
    application.aboutToQuit.connect(BackgroundCall.drain)

    icon_path = service.icon_path()
    if icon_path is not None:
        application.setWindowIcon(QIcon(str(icon_path)))

    window = MainWindow()
    window.show()
    return application.exec()


if __name__ == "__main__":
    raise SystemExit(main())
