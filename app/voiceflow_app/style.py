"""
.section-hint { font-size: 12px; color: rgba(255,255,255,0.55); }
.header-page-title { font-size: 15px; font-weight: 600; color: #f5f5f7; margin-left: 8px; }
Design tokens and application-wide GTK CSS for the native dark interface."""

from __future__ import annotations

import gi

gi.require_version("Gtk", "4.0")
from gi.repository import Gdk, Gtk  # noqa: E402


# Layout tokens. Widget constructors import these instead of inventing local gaps.
SPACE_4 = 4
SPACE_8 = 8
SPACE_12 = 12
SPACE_16 = 16
SPACE_20 = 20
SPACE_24 = 24
SPACE_32 = 32
SPACE_48 = 48
SPACING_GRID = (SPACE_4, SPACE_8, SPACE_12, SPACE_16, SPACE_20, SPACE_24, SPACE_32, SPACE_48)

WINDOW_WIDTH = 1536
WINDOW_HEIGHT = 1032
WINDOW_MIN_WIDTH = 1080
WINDOW_MIN_HEIGHT = 720
SIDEBAR_WIDTH = 248
PAGE_MAX_WIDTH = 1120
PAGE_TIGHTENING_WIDTH = 960
MOTION_MS = 150
REVEAL_MS = 200


CSS = r"""
@define-color window_bg #0d0d0f;
@define-color sidebar_bg #131316;
@define-color card_bg #1b1b1e;
@define-color raised_bg #232327;
@define-color text_primary #ffffff;
@define-color recording #ff453a;
@define-color border rgba(255,255,255,0.07);
@define-color text_secondary rgba(255,255,255,0.55);
@define-color text_tertiary rgba(255,255,255,0.35);
@define-color section_text rgba(255,255,255,0.45);
@define-color focus_ring rgba(255,255,255,0.25);

@keyframes recording-pulse {
  0% { opacity: 1; }
  50% { opacity: 0.35; }
  100% { opacity: 1; }
}

window.voiceflow-window,
.voiceflow-root {
  background-color: @window_bg;
  color: @text_primary;
  font-size: 13px;
  font-weight: 400;
}

button,
entry,
row,
switch,
scale {
  transition: background-color 150ms ease, color 150ms ease,
              border-color 150ms ease, box-shadow 150ms ease,
              opacity 150ms ease;
}

button:focus-visible,
switch:focus-visible,
scale:focus-visible {
  outline: 1px solid @focus_ring;
  outline-offset: -1px;
}

row:focus-visible {
  outline: none;
  box-shadow: inset 0 0 0 1px rgba(255,255,255,0.12);
}

.sidebar {
  background-color: @sidebar_bg;
  border-right: 1px solid @border;
  min-width: 248px;
}

.brand-row {
  padding: 20px 16px 16px 20px;
}

.brand-wave {
  min-width: 16px;
  min-height: 16px;
}

.brand-wave-bar {
  background-color: @text_primary;
  border-radius: 999px;
  min-width: 2px;
}

.brand-wave-short { min-height: 8px; }
.brand-wave-tall { min-height: 16px; }

.brand-name {
  color: @text_primary;
  font-size: 15px;
  font-weight: 700;
}

.sidebar-list {
  background-color: transparent;
  padding: 4px 0;
}

.sidebar-list row {
  background-color: transparent;
  color: @text_secondary;
  border-radius: 8px;
  margin: 0 12px;
  min-height: 40px;
}

.sidebar-list row:hover {
  background-color: rgba(255,255,255,0.04);
  color: @text_primary;
}

.sidebar-list row:active {
  background-color: rgba(255,255,255,0.02);
}

.sidebar-list row:selected {
  background-color: @raised_bg;
  color: @text_primary;
}
.sidebar-list row:selected:hover { background-color: shade(@raised_bg, 1.04); }
.sidebar-list row:selected:active { background-color: shade(@raised_bg, 1.02); }

.nav-content { padding: 0 12px 0 16px; }
.nav-label { color: inherit; font-size: 13px; font-weight: 500; }
.nav-icon { color: inherit; -gtk-icon-size: 16px; }
.nav-indicator {
  background-color: transparent;
  border-radius: 2px;
  min-width: 3px;
  min-height: 24px;
}
.sidebar-list row:selected .nav-indicator { background-color: @text_primary; }

.sidebar-footer { padding: 16px 20px 20px; }
.daemon-footer-label { color: @text_secondary; font-size: 12px; font-weight: 400; }
.version-label { color: @text_tertiary; font-size: 12px; font-weight: 400; }
.status-dot { color: @text_tertiary; font-size: 12px; }
.status-dot.ready { color: @text_secondary; }
.status-dot.offline { color: @text_tertiary; }

headerbar.content-header {
  background-color: @window_bg;
  border-bottom: 1px solid @border;
  box-shadow: none;
  min-height: 48px;
}
headerbar.content-header button:hover { background-color: rgba(255,255,255,0.04); }
headerbar.content-header button:active { background-color: rgba(255,255,255,0.02); }

.page-scroll,
.page-clamp { background-color: @window_bg; }
.page-content { padding: 32px 32px 24px; }
.page-title { color: @text_primary; font-size: 22px; font-weight: 700; }
.page-subtitle { color: @text_secondary; font-size: 13px; font-weight: 400; }
.card-title { color: @text_primary; font-size: 15px; font-weight: 600; }
.body-text { color: @text_primary; font-size: 13px; font-weight: 400; }
.secondary-text { color: @text_secondary; font-size: 12px; font-weight: 400; }
.tertiary-text { color: @text_tertiary; font-size: 12px; font-weight: 400; }
.section-label {
  color: @section_text;
  font-size: 11px;
  font-weight: 600;
  letter-spacing: 0.08em;
}
.muted { color: @text_secondary; font-size: 13px; font-weight: 400; }
.tertiary { color: @text_tertiary; font-size: 12px; font-weight: 400; }

.card {
  background-color: @card_bg;
  border: 1px solid @border;
  border-radius: 12px;
  box-shadow: none;
}
.content-card,
.hero-card,
.stat-card,
.latest-card,
.chart-card,
.empty-state { padding: 20px; }

.hero-card { min-height: 128px; }
.hero-icon-shell {
  background-color: @raised_bg;
  border-radius: 12px;
  min-width: 48px;
  min-height: 48px;
}
.hero-icon { color: @text_primary; -gtk-icon-size: 24px; }
.hero-state { color: @text_primary; font-size: 15px; font-weight: 600; }
.room-share {
  min-height: 4px;
}
.room-share trough {
  min-height: 4px;
  border-radius: 3px;
  background-color: alpha(@text_primary, 0.08);
}
.room-share progress {
  min-height: 4px;
  border-radius: 3px;
  background-color: alpha(@text_primary, 0.45);
}
.recording-dot {
  color: @recording;
  font-size: 13px;
  animation: recording-pulse 1200ms ease-in-out infinite;
}
.hero-meta { color: @text_secondary; font-size: 12px; font-weight: 400; }

.stat-card {
  min-height: 88px;
  padding: 16px 20px;
}
.stat-heading-icon { color: @text_secondary; -gtk-icon-size: 16px; }
.stat-label {
  color: @text_secondary;
  font-size: 11px;
  font-weight: 600;
  letter-spacing: 0.06em;
}
.stat-value {
  color: @text_primary;
  font-size: 40px;
  font-weight: 700;
  font-feature-settings: "tnum";
}
.stat-suffix { color: @text_secondary; font-size: 12px; font-weight: 400; }
.stat-trend { color: @section_text; font-size: 12px; font-weight: 400; }

button.primary-button,
button.secondary-button,
button.icon-button,
button.destructive-button {
  border-radius: 8px;
  min-height: 40px;
  box-shadow: none;
  font-size: 13px;
  font-weight: 600;
}

button.primary-button {
  background-color: @text_primary;
  color: @window_bg;
  border: 1px solid @text_primary;
  padding: 0 16px;
}
button.primary-button:hover { background-color: shade(@text_primary, 0.96); }
button.primary-button:active { background-color: shade(@text_primary, 0.98); }
button.primary-button:disabled { opacity: 0.35; }

button.secondary-button {
  background-color: @raised_bg;
  color: @text_primary;
  border: 1px solid @border;
  padding: 0 16px;
}
button.secondary-button:hover { background-color: shade(@raised_bg, 1.04); }
button.secondary-button:active { background-color: shade(@raised_bg, 1.02); }
button.secondary-button:disabled { opacity: 0.35; }

button.icon-button {
  background-color: @raised_bg;
  color: @text_secondary;
  border: 1px solid @border;
  min-width: 40px;
  padding: 0;
}
button.icon-button:hover {
  color: @text_primary;
  background-color: shade(@raised_bg, 1.04);
}
button.icon-button:active { background-color: shade(@raised_bg, 1.02); }

button.recording-action {
  background-color: @raised_bg;
  color: @text_primary;
  border: 1px solid @recording;
}
button.recording-action:hover { background-color: shade(@raised_bg, 1.04); }
button.recording-action:active { background-color: shade(@raised_bg, 1.02); }

button.destructive-button {
  background-color: transparent;
  color: @text_secondary;
  border: 1px solid transparent;
  padding: 0 12px;
}
button.destructive-button:hover { background-color: rgba(255,255,255,0.04); }
button.destructive-button:active { background-color: rgba(255,255,255,0.02); }
button.destructive-button.confirming { border-color: @border; }

.latest-meta,
.history-meta {
  color: @text_tertiary;
  font-size: 12px;
  font-weight: 400;
  font-feature-settings: "tnum";
}
.history-preview { color: @text_secondary; font-size: 13px; font-weight: 400; }
.history-full-text { color: @text_primary; font-size: 13px; font-weight: 400; }
.history-card { padding: 0; }
button.history-toggle {
  background-color: transparent;
  color: @text_primary;
  border: 0;
  border-radius: 12px;
  box-shadow: none;
  padding: 20px;
}
button.history-toggle:hover { background-color: @raised_bg; }
button.history-toggle:active { background-color: shade(@raised_bg, 1.02); }
.history-chevron {
  color: @text_secondary;
  -gtk-icon-size: 16px;
  transition: -gtk-icon-transform 150ms ease, color 150ms ease;
}
.history-chevron.expanded {
  color: @text_primary;
  -gtk-icon-transform: rotate(90deg);
}
.history-detail {
  border-top: 1px solid @border;
  padding: 20px;
}

entry.search-entry,
entry.flat-entry {
  background-color: @raised_bg;
  color: @text_primary;
  border: 1px solid @border;
  border-radius: 8px;
  min-height: 40px;
  box-shadow: none;
  font-size: 13px;
}
entry.search-entry:hover,
entry.flat-entry:hover { background-color: mix(@raised_bg, @text_primary, 0.02); }
entry.search-entry:active,
entry.flat-entry:active { background-color: shade(@raised_bg, 1.01); }
entry.search-entry:focus,
entry.search-entry:focus-visible,
entry.flat-entry:focus,
entry.flat-entry:focus-visible {
  background-color: mix(@raised_bg, @text_primary, 0.02);
  border: 1px solid @focus_ring;
  outline: none;
  box-shadow: none;
}
.monospace-entry { font-family: monospace; font-feature-settings: "tnum"; }

.settings-card { padding: 4px 0; }
.settings-card row {
  background-color: transparent;
  border-bottom: 1px solid @border;
  min-height: 64px;
  padding: 4px 16px;
}
.settings-card row:last-child { border-bottom: 0; }
.settings-card row:hover { background-color: rgba(255,255,255,0.02); }
.settings-card row:active { background-color: rgba(255,255,255,0.01); }
.settings-card row:focus-visible {
  outline: none;
  box-shadow: inset 0 0 0 1px rgba(255,255,255,0.12);
}
.settings-card .title { color: @text_primary; font-size: 13px; font-weight: 600; }
.settings-card .subtitle { color: @text_secondary; font-size: 12px; font-weight: 400; }
.settings-card row.inactive .title,
.settings-card row.inactive .subtitle { color: @text_tertiary; }
.settings-card row.detected .title { color: @text_primary; }
.volume-value {
  color: @text_secondary;
  font-size: 12px;
  font-weight: 500;
  font-feature-settings: "tnum";
}
button.settings-link {
  background-color: transparent;
  color: @text_secondary;
  border: 0;
  box-shadow: none;
}
button.settings-link:hover { color: @text_primary; background-color: rgba(255,255,255,0.02); }

switch { background-color: @raised_bg; color: @text_primary; }
switch:hover { background-color: shade(@raised_bg, 1.04); }
switch:active { background-color: shade(@raised_bg, 1.02); }
switch:checked { background-color: @text_secondary; }
switch slider { background-color: @text_primary; }
scale:hover trough { background-color: shade(@raised_bg, 1.04); }
scale:active trough { background-color: shade(@raised_bg, 1.02); }
scale highlight { background-color: @text_primary; }
scale trough { background-color: @raised_bg; }

.chip-flow { background-color: transparent; }
.chip-flow > flowboxchild {
  background-color: transparent;
  border-radius: 999px;
  padding: 0;
}
.chip {
  background-color: @raised_bg;
  border: 1px solid @border;
  border-radius: 999px;
  padding: 4px 4px 4px 12px;
  min-height: 32px;
}
.chip-label { color: @text_primary; font-size: 13px; font-weight: 400; }
button.chip-remove {
  background-color: transparent;
  color: @text_secondary;
  border: 0;
  border-radius: 999px;
  box-shadow: none;
  min-width: 24px;
  min-height: 24px;
  padding: 0;
}
button.chip-remove:hover { background-color: rgba(255,255,255,0.04); color: @text_primary; }
button.chip-remove:active { background-color: rgba(255,255,255,0.02); }
button.chip-remove:focus-visible { outline: 2px solid @focus_ring; outline-offset: -2px; }

.vocabulary-grid { background-color: transparent; }
.vocabulary-grid > flowboxchild {
  background-color: transparent;
  border: 0;
  border-radius: 8px;
  padding: 0;
}
.vocabulary-grid > flowboxchild:focus-visible {
  outline: none;
  box-shadow: inset 0 0 0 1px @focus_ring;
}
.vocabulary-tile {
  background-color: #1b1b1e;
  border: 1px solid @border;
  border-radius: 8px;
  min-height: 56px;
}
.vocabulary-term {
  color: @text_primary;
  font-size: 13px;
  font-weight: 500;
  padding: 12px 16px;
}
button.vocabulary-remove {
  background-color: rgba(13,13,15,0.82);
  color: @text_secondary;
  border: 0;
  border-radius: 999px;
  box-shadow: none;
  min-width: 24px;
  min-height: 24px;
  margin: 4px;
  padding: 0;
  opacity: 0;
}
.vocabulary-grid > flowboxchild:hover button.vocabulary-remove,
button.vocabulary-remove:hover,
button.vocabulary-remove:focus-visible { opacity: 1; color: @text_primary; }
button.vocabulary-remove:hover { background-color: @raised_bg; }
button.vocabulary-remove:focus-visible {
  outline: 1px solid @focus_ring;
  outline-offset: -1px;
}

.empty-state { min-height: 96px; }
.empty-icon { color: @text_tertiary; -gtk-icon-size: 32px; }
.empty-message { color: @text_secondary; font-size: 13px; font-weight: 400; }

.dirty-bar {
  background-color: @card_bg;
  border: 1px solid @border;
  border-radius: 12px;
  box-shadow: inset 0 1px 0 rgba(255,255,255,0.04);
  padding: 12px 16px;
  margin: 0 16px 16px;
}
.dirty-label { color: @text_primary; font-size: 13px; font-weight: 600; }

.chart-card { min-height: 240px; }
drawingarea { background-color: transparent; }
.chart-unavailable {
  color: @text_secondary;
  font-size: 12px;
  font-weight: 400;
  min-height: 160px;
}
.chart-unavailable.compact {
  color: @text_tertiary;
  font-size: 11px;
  min-height: 48px;
}
tooltip {
  background-color: @raised_bg;
  color: @text_primary;
  border: 1px solid @border;
  border-radius: 8px;
}

.error-page { padding: 48px; }
.error-title { color: @text_primary; font-size: 22px; font-weight: 700; }
.error-icon { color: @text_tertiary; -gtk-icon-size: 32px; }
"""


def install() -> None:
    """Install the global CSS provider for the current display."""
    display = Gdk.Display.get_default()
    if display is None:
        return
    provider = Gtk.CssProvider()
    provider.load_from_string(CSS)
    Gtk.StyleContext.add_provider_for_display(
        display, provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
    )
