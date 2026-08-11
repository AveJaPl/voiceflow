"""The voiceflow desktop window for Windows.

Linux has the GTK4/libadwaita application in ``app/``; PyGObject publishes no
Windows wheel, so this is its Qt counterpart. It talks to the daemon over the
same local control channel the command line uses, and edits the same
``config.yaml`` — the window is a front end, never a second source of truth.
"""

from __future__ import annotations

import logging
import sys

from PySide6.QtCore import QTimer, Qt
from PySide6.QtGui import QIcon
from PySide6.QtWidgets import (
    QApplication,
    QButtonGroup,
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
from voiceflow.gui.pages.settings import SettingsPage
from voiceflow.gui.pages.stats import StatsPage
from voiceflow.gui.pages.vocabulary import VocabularyPage
from voiceflow.gui.widgets import BackgroundCall
from voiceflow.updates import installed_version

LOGGER = logging.getLogger(__name__)

#: The dashboard is live, so it repolls; the rest refresh when opened.
DASHBOARD_POLL_MS = 2500
TOAST_MS = 3200

PAGES = (
    ("dashboard", "Przegląd"),
    ("history", "Historia"),
    ("stats", "Statystyki"),
    ("settings", "Ustawienia"),
    ("vocabulary", "Słownik"),
)


class MainWindow(QMainWindow):
    def __init__(self) -> None:
        super().__init__()
        self.setWindowTitle("voiceflow")
        self.resize(theme.WINDOW_WIDTH, theme.WINDOW_HEIGHT)
        self.setMinimumSize(theme.WINDOW_MIN_WIDTH, theme.WINDOW_MIN_HEIGHT)

        root = QWidget()
        root.setObjectName("page-host")
        layout = QHBoxLayout(root)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(0)

        self._stack = QStackedWidget()
        self._pages: dict[str, QWidget] = {
            "dashboard": DashboardPage(self),
            "history": HistoryPage(self),
            "stats": StatsPage(self),
            "settings": SettingsPage(self),
            "vocabulary": VocabularyPage(self),
        }
        layout.addWidget(self._build_sidebar())
        for _key, page in self._pages.items():
            self._stack.addWidget(page)

        content = QWidget()
        content_layout = QVBoxLayout(content)
        content_layout.setContentsMargins(0, 0, 0, 0)
        content_layout.setSpacing(0)
        content_layout.addWidget(self._stack, 1)
        content_layout.addWidget(self._build_toast())
        layout.addWidget(content, 1)

        self.setCentralWidget(root)

        self._current = "dashboard"
        self._pages["dashboard"].refresh()

        self._poll = QTimer(self)
        self._poll.setInterval(DASHBOARD_POLL_MS)
        self._poll.timeout.connect(self._poll_dashboard)
        self._poll.start()

    # -- chrome --------------------------------------------------------------

    def _build_sidebar(self) -> QWidget:
        sidebar = QWidget()
        sidebar.setObjectName("sidebar")
        sidebar.setFixedWidth(theme.SIDEBAR_WIDTH)
        layout = QVBoxLayout(sidebar)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(0)

        brand = QLabel("voiceflow")
        brand.setObjectName("brand")
        layout.addWidget(brand)
        subtitle = QLabel("dyktowanie lokalne")
        subtitle.setObjectName("brand-sub")
        layout.addWidget(subtitle)

        self._nav_group = QButtonGroup(self)
        self._nav_group.setExclusive(True)
        for key, title in PAGES:
            button = QPushButton(title)
            button.setObjectName("nav-button")
            button.setCheckable(True)
            button.setCursor(Qt.CursorShape.PointingHandCursor)
            button.clicked.connect(lambda _checked=False, name=key: self.show_page(name))
            if key == "dashboard":
                button.setChecked(True)
            self._nav_group.addButton(button)
            layout.addWidget(button)

        layout.addStretch(1)
        foot = QLabel(f"wersja {installed_version()}")
        foot.setObjectName("sidebar-foot")
        layout.addWidget(foot)
        return sidebar

    def _build_toast(self) -> QWidget:
        self._toast = QLabel("")
        self._toast.setObjectName("toast")
        self._toast.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self._toast.hide()
        holder = QWidget()
        layout = QHBoxLayout(holder)
        layout.setContentsMargins(36, 0, 36, 16)
        layout.addStretch(1)
        layout.addWidget(self._toast)
        layout.addStretch(1)
        self._toast_timer = QTimer(self)
        self._toast_timer.setSingleShot(True)
        self._toast_timer.timeout.connect(self._toast.hide)
        return holder

    # -- page coordination ---------------------------------------------------

    def show_page(self, name: str) -> None:
        page = self._pages.get(name)
        if page is None:
            return
        self._current = name
        self._stack.setCurrentWidget(page)
        page.refresh()

    def refresh_current(self) -> None:
        self._pages[self._current].refresh()

    def _poll_dashboard(self) -> None:
        # Only the visible dashboard polls: background pages hitting the daemon
        # every few seconds would be pure waste.
        if self._current == "dashboard" and self.isVisible():
            self._pages["dashboard"].refresh()

    def notify(self, message: str, *, tone: str = "info") -> None:
        self._toast.setText(message)
        self._toast.setProperty("tone", tone)
        # Qt only restyles on an explicit repolish after a property change.
        self._toast.style().unpolish(self._toast)
        self._toast.style().polish(self._toast)
        self._toast.show()
        self._toast_timer.start(TOAST_MS)

    def closeEvent(self, event) -> None:  # noqa: N802 - Qt naming
        # Closing the window must not take the daemon with it: dictation is the
        # product, this is only its control panel.
        self._poll.stop()
        BackgroundCall.drain()
        super().closeEvent(event)


def main(argv: list[str] | None = None) -> int:
    """Open the desktop window."""
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
