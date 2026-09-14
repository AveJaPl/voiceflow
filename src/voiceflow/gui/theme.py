"""Design tokens and the application-wide stylesheet for the Windows window.

This is a port of ``app/voiceflow_app/style.py``, token for token and rule for
rule: the same near-black surfaces, the same white primary button, the same
12 px cards, the same type scale. Where GTK CSS has no Qt equivalent — the
recording pulse, the switch, the navigation indicator — the effect is painted
by a widget in :mod:`voiceflow.gui.widgets` instead of being dropped.

Reading this file next to ``style.py`` is the intended way to check that the
two applications still look alike.
"""

from __future__ import annotations

# -- layout tokens -----------------------------------------------------------
# Widget constructors import these instead of inventing local gaps, exactly as
# the GTK side does.

SPACE_4 = 4
SPACE_8 = 8
SPACE_12 = 12
SPACE_16 = 16
SPACE_20 = 20
SPACE_24 = 24
SPACE_32 = 32
SPACE_48 = 48

WINDOW_WIDTH = 1536
WINDOW_HEIGHT = 1032
WINDOW_MIN_WIDTH = 1080
WINDOW_MIN_HEIGHT = 720
SIDEBAR_WIDTH = 248
PAGE_MAX_WIDTH = 1120
PAGE_TIGHTENING_WIDTH = 960
MOTION_MS = 150
REVEAL_MS = 200

# -- colour tokens -----------------------------------------------------------

WINDOW_BG = "#0d0d0f"
SIDEBAR_BG = "#131316"
CARD_BG = "#1b1b1e"
RAISED_BG = "#232327"
TEXT_PRIMARY = "#ffffff"
RECORDING = "#ff453a"
BORDER = "rgba(255,255,255,0.07)"
TEXT_SECONDARY = "rgba(255,255,255,0.55)"
TEXT_TERTIARY = "rgba(255,255,255,0.35)"
SECTION_TEXT = "rgba(255,255,255,0.45)"
FOCUS_RING = "rgba(255,255,255,0.25)"

#: Solid equivalents, for the painted widgets — QPainter takes no rgba() text.
BORDER_SOLID = "#26262b"
TEXT_SECONDARY_SOLID = "#8f8f96"
TEXT_TERTIARY_SOLID = "#5c5c66"

#: Status colours, for the few places that must say good/bad rather than merely
#: quiet: the hotkey probe, a shortcut Windows refused, a failed save. The GTK
#: application spends these sparingly too — the palette is otherwise greyscale.
ACCENT = RECORDING
POSITIVE = "#32d74b"
WARNING = "#ff9f0a"
MUTED = TEXT_SECONDARY_SOLID
FAINT = TEXT_TERTIARY_SOLID

#: Activity heat ramp for the 26-week grid. The GTK page draws it as white at
#: five alpha steps; these are those steps flattened onto the card colour, so
#: both grids read identically.
HEAT = ("#242427", "#4a4a4e", "#6a6a70", "#6a6a70", "#ffffff")

#: The alphas the GTK charts use, for painters that can set opacity directly.
CHART_ALPHA_IDLE = 0.07
CHART_ALPHA_ACTIVE = 0.55

FONT_FAMILY = "Segoe UI Variable Text, Segoe UI, Inter, sans-serif"
MONO_FAMILY = "Cascadia Mono, Consolas, monospace"

STYLESHEET = f"""
QWidget {{
    background-color: {WINDOW_BG};
    color: {TEXT_PRIMARY};
    font-family: {FONT_FAMILY};
    font-size: 13px;
    font-weight: 400;
}}

/* Text controls must not repaint the page colour over the card they sit on. */
QLabel, QCheckBox, QRadioButton {{ background: transparent; }}
/* Layout-only containers. Anything that merely holds a row of widgets carries
   this name, so a card's colour shows through instead of being covered. */
#plain {{ background: transparent; }}

QMainWindow, #page-host, #page-scroll, #page-clamp {{ background-color: {WINDOW_BG}; }}
QScrollArea, QScrollArea > QWidget > QWidget {{ background-color: {WINDOW_BG}; }}

/* -- sidebar ---------------------------------------------------------- */
#sidebar {{
    background-color: {SIDEBAR_BG};
    border-right: 1px solid {BORDER};
}}
#brand-name {{
    color: {TEXT_PRIMARY};
    font-size: 15px;
    font-weight: 700;
}}
#nav-button {{
    background-color: transparent;
    border: none;
    border-radius: 8px;
    color: {TEXT_SECONDARY};
    font-size: 13px;
    font-weight: 500;
    min-height: 40px;
    padding: 0 12px 0 16px;
    text-align: left;
}}
#nav-button:hover {{ background-color: rgba(255,255,255,0.04); color: {TEXT_PRIMARY}; }}
#nav-button:pressed {{ background-color: rgba(255,255,255,0.02); }}
#nav-button:checked {{ background-color: {RAISED_BG}; color: {TEXT_PRIMARY}; }}
#daemon-footer-label {{ color: {TEXT_SECONDARY}; font-size: 12px; }}
#version-label {{ color: {TEXT_TERTIARY}; font-size: 12px; }}

/* -- header bar ------------------------------------------------------- */
#content-header {{
    background-color: {WINDOW_BG};
    border-bottom: 1px solid {BORDER};
}}
#header-page-title {{
    color: {TEXT_PRIMARY};
    font-size: 15px;
    font-weight: 600;
}}

/* -- page furniture --------------------------------------------------- */
#page-title {{ color: {TEXT_PRIMARY}; font-size: 22px; font-weight: 700; }}
#page-subtitle {{ color: {TEXT_SECONDARY}; font-size: 13px; }}
#card-title {{ color: {TEXT_PRIMARY}; font-size: 15px; font-weight: 600; }}
#body-text {{ color: {TEXT_PRIMARY}; font-size: 13px; }}
#secondary-text {{ color: {TEXT_SECONDARY}; font-size: 12px; }}
#tertiary-text {{ color: {TEXT_TERTIARY}; font-size: 12px; }}
#section-label {{
    color: {SECTION_TEXT};
    font-size: 11px;
    font-weight: 600;
    letter-spacing: 1px;
}}
#section-hint {{ color: {TEXT_SECONDARY}; font-size: 12px; }}
#muted {{ color: {TEXT_SECONDARY}; font-size: 13px; }}
#tertiary, #faint {{ color: {TEXT_TERTIARY}; font-size: 12px; }}

#card {{
    background-color: {CARD_BG};
    border: 1px solid {BORDER};
    border-radius: 12px;
}}
#hero-icon-shell {{
    background-color: {RAISED_BG};
    border-radius: 12px;
}}
#hero-state {{ color: {TEXT_PRIMARY}; font-size: 15px; font-weight: 600; }}
#hero-meta {{ color: {TEXT_SECONDARY}; font-size: 12px; }}

#stat-label {{
    color: {TEXT_SECONDARY};
    font-size: 11px;
    font-weight: 600;
    letter-spacing: 0.7px;
}}
#stat-value {{ color: {TEXT_PRIMARY}; font-size: 40px; font-weight: 700; }}
#stat-suffix {{ color: {TEXT_SECONDARY}; font-size: 12px; }}
#stat-trend {{ color: {SECTION_TEXT}; font-size: 12px; }}

/* -- buttons ---------------------------------------------------------- */
QPushButton {{
    background-color: {RAISED_BG};
    color: {TEXT_PRIMARY};
    border: 1px solid {BORDER};
    border-radius: 8px;
    min-height: 40px;
    padding: 0 16px;
    font-size: 13px;
    font-weight: 600;
}}
QPushButton:hover {{ background-color: #26262a; }}
QPushButton:pressed {{ background-color: #242428; }}
QPushButton:disabled {{ color: {TEXT_TERTIARY}; }}

QPushButton#primary-button {{
    background-color: {TEXT_PRIMARY};
    color: {WINDOW_BG};
    border: 1px solid {TEXT_PRIMARY};
}}
QPushButton#primary-button:hover {{ background-color: #f5f5f5; border-color: #f5f5f5; }}
QPushButton#primary-button:pressed {{ background-color: #fafafa; }}
QPushButton#primary-button:disabled {{ background-color: #4a4a4d; border-color: #4a4a4d; color: #1b1b1e; }}

QPushButton#secondary-button {{
    background-color: {RAISED_BG};
    color: {TEXT_PRIMARY};
    border: 1px solid {BORDER};
}}
QPushButton#secondary-button:hover {{ background-color: #26262a; }}

QPushButton#icon-button {{
    background-color: {RAISED_BG};
    color: {TEXT_SECONDARY};
    border: 1px solid {BORDER};
    min-width: 40px;
    max-width: 40px;
    padding: 0;
}}
QPushButton#icon-button:hover {{ background-color: #26262a; }}

QPushButton#recording-action {{
    background-color: {RAISED_BG};
    color: {TEXT_PRIMARY};
    border: 1px solid {RECORDING};
}}
QPushButton#recording-action:hover {{ background-color: #26262a; }}

QPushButton#destructive-button {{
    background-color: transparent;
    color: {TEXT_SECONDARY};
    border: 1px solid transparent;
    padding: 0 12px;
}}
QPushButton#destructive-button:hover {{ background-color: rgba(255,255,255,0.04); }}
QPushButton#destructive-button[confirming="true"] {{ border-color: {BORDER_SOLID}; color: {TEXT_PRIMARY}; }}

QPushButton#settings-link {{
    background-color: transparent;
    color: {TEXT_SECONDARY};
    border: none;
    font-weight: 400;
    text-align: left;
    padding: 0;
}}
QPushButton#settings-link:hover {{ color: {TEXT_PRIMARY}; }}

QPushButton#history-toggle {{
    background-color: transparent;
    color: {TEXT_PRIMARY};
    border: none;
    border-radius: 12px;
    padding: 20px;
    text-align: left;
}}
QPushButton#history-toggle:hover {{ background-color: {RAISED_BG}; }}

QPushButton#chip-remove, QPushButton#vocabulary-remove {{
    background-color: transparent;
    color: {TEXT_SECONDARY};
    border: none;
    border-radius: 12px;
    min-width: 24px;
    max-width: 24px;
    min-height: 24px;
    max-height: 24px;
    padding: 0;
}}
QPushButton#chip-remove:hover, QPushButton#vocabulary-remove:hover {{
    background-color: rgba(255,255,255,0.06);
    color: {TEXT_PRIMARY};
}}

/* -- text fields ------------------------------------------------------ */
QLineEdit, QPlainTextEdit, QSpinBox, QDoubleSpinBox, QComboBox {{
    background-color: {RAISED_BG};
    color: {TEXT_PRIMARY};
    border: 1px solid {BORDER};
    border-radius: 8px;
    min-height: 40px;
    padding: 0 12px;
    font-size: 13px;
    selection-background-color: rgba(255,255,255,0.20);
}}
QLineEdit:focus, QPlainTextEdit:focus, QSpinBox:focus,
QDoubleSpinBox:focus, QComboBox:focus {{ border: 1px solid {FOCUS_RING}; }}
QLineEdit#monospace-entry {{ font-family: {MONO_FAMILY}; }}
/* The arrow is painted by the widget (see widgets.Combo), because Qt's own
   ::down-arrow wants an image file we would have to ship. */
QComboBox::drop-down {{ border: none; width: 26px; }}
QComboBox::down-arrow {{ height: 0; width: 0; }}
QComboBox QAbstractItemView {{
    background-color: {RAISED_BG};
    border: 1px solid {BORDER};
    outline: none;
    selection-background-color: rgba(255,255,255,0.10);
}}
QSpinBox::up-button, QSpinBox::down-button,
QDoubleSpinBox::up-button, QDoubleSpinBox::down-button {{ width: 18px; }}

/* -- settings rows ---------------------------------------------------- */
#settings-card {{
    background-color: {CARD_BG};
    border: 1px solid {BORDER};
    border-radius: 12px;
}}
#settings-row {{ background: transparent; border-bottom: 1px solid {BORDER}; }}
#settings-row[last="true"] {{ border-bottom: none; }}
#row-title {{ color: {TEXT_PRIMARY}; font-size: 13px; font-weight: 600; }}
#row-subtitle {{ color: {TEXT_SECONDARY}; font-size: 12px; }}
#settings-row[inactive="true"] #row-title,
#settings-row[inactive="true"] #row-subtitle {{ color: {TEXT_TERTIARY}; }}
#volume-value {{ color: {TEXT_SECONDARY}; font-size: 12px; font-weight: 500; }}

/* -- sliders ---------------------------------------------------------- */
QSlider::groove:horizontal {{ background: {RAISED_BG}; border-radius: 3px; height: 6px; }}
QSlider::sub-page:horizontal {{ background: {TEXT_PRIMARY}; border-radius: 3px; }}
QSlider::add-page:horizontal {{ background: {RAISED_BG}; border-radius: 3px; }}
QSlider::handle:horizontal {{
    background: {TEXT_PRIMARY};
    border-radius: 7px;
    margin: -4px 0;
    width: 14px;
}}
QSlider:disabled::sub-page:horizontal {{ background: #55555a; }}
QSlider:disabled::handle:horizontal {{ background: #55555a; }}

/* -- history ---------------------------------------------------------- */
#history-meta, #latest-meta {{ color: {TEXT_TERTIARY}; font-size: 12px; }}
#history-preview {{ color: {TEXT_SECONDARY}; font-size: 13px; }}
#history-full-text {{ color: {TEXT_PRIMARY}; font-size: 13px; }}
#history-detail {{ background: transparent; border-top: 1px solid {BORDER}; }}

/* -- vocabulary ------------------------------------------------------- */
#vocabulary-tile {{
    background-color: {CARD_BG};
    border: 1px solid {BORDER};
    border-radius: 8px;
}}
#vocabulary-term {{ color: {TEXT_PRIMARY}; font-size: 13px; font-weight: 500; }}

/* -- empty state ------------------------------------------------------ */
#empty-message {{ color: {TEXT_SECONDARY}; font-size: 13px; }}

/* -- unsaved-changes bar ---------------------------------------------- */
#dirty-bar {{
    background-color: {CARD_BG};
    border: 1px solid {BORDER};
    border-radius: 12px;
}}
#dirty-label {{ color: {TEXT_PRIMARY}; font-size: 13px; font-weight: 600; }}

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
    background-color: {RAISED_BG};
    border: 1px solid {BORDER_SOLID};
    border-radius: 8px;
    color: {TEXT_PRIMARY};
    padding: 6px 9px;
}}

/* -- transient message ------------------------------------------------ */
#toast {{
    background-color: {RAISED_BG};
    border: 1px solid {BORDER_SOLID};
    border-radius: 12px;
    padding: 12px 18px;
    font-size: 13px;
}}

/* -- malformed-config shell ------------------------------------------- */
#error-title {{ color: {TEXT_PRIMARY}; font-size: 22px; font-weight: 700; }}
"""
