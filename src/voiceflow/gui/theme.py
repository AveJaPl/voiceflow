"""Palette and stylesheet for the Windows desktop window.

The colours are the ones the GTK application and the on-screen overlay already
use, so the three surfaces read as one product. Qt's default widget styling is
replaced wholesale: the point of this file is that nothing looks like a
1990s dialog box.
"""

from __future__ import annotations

#: Matte near-black surfaces, lightest last.
BACKGROUND = "#0d0d0f"
SURFACE = "#131316"
CARD = "#1b1b1e"
RAISED = "#232327"
BORDER = "#26262b"

TEXT = "#f5f5f7"
MUTED = "#8b8b96"
FAINT = "#5c5c66"

#: The recording red shared with the overlay dot.
ACCENT = "#ff453a"
ACCENT_DIM = "#3a1614"
POSITIVE = "#32d74b"
WARNING = "#ff9f0a"

#: Activity heat ramp, index 0 (idle) through 4 (busiest quartile). Idle sits
#: one step above the card it is drawn on, so the grid still reads as a grid on
#: a quiet week instead of dissolving into the background.
HEAT = ("#26262b", "#4a1a17", "#8c2a21", "#cc352b", "#ff453a")

WINDOW_WIDTH = 1440
WINDOW_HEIGHT = 920
WINDOW_MIN_WIDTH = 1024
WINDOW_MIN_HEIGHT = 680
SIDEBAR_WIDTH = 248
PAGE_MAX_WIDTH = 1120

FONT_FAMILY = "Segoe UI Variable Text, Segoe UI, Inter, sans-serif"

STYLESHEET = f"""
QWidget {{
    background-color: {BACKGROUND};
    color: {TEXT};
    font-family: {FONT_FAMILY};
    font-size: 14px;
}}

QMainWindow, #page-host {{ background-color: {BACKGROUND}; }}

/* Text controls must not repaint the page colour over whatever card they sit
   on, or every label shows up as a darker band across it. */
QLabel, QCheckBox, QRadioButton {{ background: transparent; }}

/* -- sidebar ---------------------------------------------------------- */
#sidebar {{
    background-color: {SURFACE};
    border-right: 1px solid {BORDER};
}}
#brand {{
    font-size: 19px;
    font-weight: 600;
    padding: 26px 24px 6px 24px;
}}
#brand-sub {{
    color: {FAINT};
    font-size: 12px;
    padding: 0 24px 22px 24px;
}}
#nav-button {{
    background-color: transparent;
    border: none;
    border-radius: 10px;
    color: {MUTED};
    font-size: 14.5px;
    margin: 2px 12px;
    padding: 11px 14px;
    text-align: left;
}}
#nav-button:hover {{ background-color: {CARD}; color: {TEXT}; }}
#nav-button:checked {{ background-color: {RAISED}; color: {TEXT}; font-weight: 600; }}
#sidebar-foot {{ color: {FAINT}; font-size: 11.5px; padding: 16px 24px 20px 24px; }}

/* -- page furniture --------------------------------------------------- */
#page-title {{ font-size: 27px; font-weight: 600; }}
#page-subtitle {{ color: {MUTED}; font-size: 14px; }}
#section-label {{
    color: {FAINT};
    font-size: 11px;
    font-weight: 600;
    letter-spacing: 1.4px;
}}
#card {{
    background-color: {CARD};
    border: 1px solid {BORDER};
    border-radius: 16px;
}}
#card-title {{ font-size: 15px; font-weight: 600; }}
#muted {{ color: {MUTED}; }}
#faint {{ color: {FAINT}; font-size: 12.5px; }}
#stat-value {{ font-size: 30px; font-weight: 600; }}
#stat-label {{ color: {FAINT}; font-size: 11px; font-weight: 600; letter-spacing: 1.2px; }}

/* -- controls --------------------------------------------------------- */
QPushButton {{
    background-color: {RAISED};
    border: 1px solid {BORDER};
    border-radius: 10px;
    padding: 9px 18px;
    font-size: 13.5px;
}}
QPushButton:hover {{ background-color: #2b2b31; }}
QPushButton:pressed {{ background-color: #313139; }}
QPushButton:disabled {{ color: {FAINT}; background-color: {CARD}; }}
QPushButton#primary {{
    background-color: {ACCENT};
    border: none;
    color: #ffffff;
    font-weight: 600;
}}
QPushButton#primary:hover {{ background-color: #ff5a50; }}
QPushButton#primary:disabled {{ background-color: {ACCENT_DIM}; color: {MUTED}; }}
QPushButton#danger {{ color: {ACCENT}; }}
QPushButton#danger:hover {{ background-color: {ACCENT_DIM}; }}
QPushButton#ghost {{ background-color: transparent; border: none; color: {MUTED}; }}
QPushButton#ghost:hover {{ color: {TEXT}; background-color: {RAISED}; }}

QLineEdit, QSpinBox, QDoubleSpinBox, QComboBox, QPlainTextEdit {{
    background-color: {SURFACE};
    border: 1px solid {BORDER};
    border-radius: 10px;
    padding: 9px 12px;
    selection-background-color: {ACCENT};
}}
QLineEdit:focus, QSpinBox:focus, QDoubleSpinBox:focus,
QComboBox:focus, QPlainTextEdit:focus {{ border-color: {ACCENT}; }}
QComboBox::drop-down {{ border: none; width: 26px; }}
QComboBox QAbstractItemView {{
    background-color: {RAISED};
    border: 1px solid {BORDER};
    outline: none;
    selection-background-color: {ACCENT};
}}
QSpinBox::up-button, QSpinBox::down-button,
QDoubleSpinBox::up-button, QDoubleSpinBox::down-button {{ width: 18px; }}

QCheckBox {{ spacing: 10px; }}
QCheckBox::indicator {{
    background-color: {SURFACE};
    border: 1px solid #3a3a42;
    border-radius: 6px;
    height: 19px;
    width: 19px;
}}
QCheckBox::indicator:checked {{ background-color: {ACCENT}; border-color: {ACCENT}; }}

QSlider::groove:horizontal {{ background: {RAISED}; border-radius: 3px; height: 6px; }}
QSlider::sub-page:horizontal {{ background: {ACCENT}; border-radius: 3px; }}
QSlider::handle:horizontal {{
    background: {TEXT};
    border-radius: 8px;
    margin: -6px 0;
    width: 16px;
}}

/* -- scrolling -------------------------------------------------------- */
QScrollArea {{ border: none; }}
QScrollBar:vertical {{ background: transparent; width: 10px; margin: 4px; }}
QScrollBar::handle:vertical {{ background: #2f2f36; border-radius: 5px; min-height: 40px; }}
QScrollBar::handle:vertical:hover {{ background: #3c3c45; }}
QScrollBar::add-line, QScrollBar::sub-line {{ height: 0; width: 0; }}
QScrollBar::add-page, QScrollBar::sub-page {{ background: none; }}
QScrollBar:horizontal {{ background: transparent; height: 10px; margin: 4px; }}
QScrollBar::handle:horizontal {{ background: #2f2f36; border-radius: 5px; min-width: 40px; }}

QToolTip {{
    background-color: {RAISED};
    border: 1px solid {BORDER};
    border-radius: 8px;
    color: {TEXT};
    padding: 6px 9px;
}}

/* -- transient message strip ------------------------------------------ */
#toast {{
    background-color: {RAISED};
    border: 1px solid {BORDER};
    border-radius: 12px;
    padding: 12px 18px;
    font-size: 13.5px;
}}
#toast[tone="error"] {{ background-color: {ACCENT_DIM}; border-color: {ACCENT}; }}
"""
