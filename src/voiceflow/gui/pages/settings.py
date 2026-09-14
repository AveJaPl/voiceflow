"""Configuration editor presented as matte application cards.

Structured group for group after ``app/voiceflow_app/pages/settings.py``: the
model, the voice chat, the ducking, the Discord status, the behaviour. Edits go
into memory and are written by the window's shared unsaved-changes bar, so a
half-finished form never reaches the daemon and unknown keys in the file are
preserved — this window is not the only writer.

The last group has no GTK counterpart: those keys exist in ``config.yaml`` on
both systems, but the GTK application does not expose them yet.
"""

from __future__ import annotations

from collections.abc import Callable, Mapping
from typing import Any

from PySide6.QtCore import QUrl, Qt
from PySide6.QtGui import QDesktopServices
from PySide6.QtWidgets import (
    QDoubleSpinBox,
    QLineEdit,
    QPushButton,
    QSpinBox,
    QVBoxLayout,
    QWidget,
)

from voiceflow.gui import service, theme
from voiceflow.gui.hotkeyfield import HotkeyField
from voiceflow.gui.widgets import (
    BackgroundCall,
    Combo,
    SettingsCard,
    SettingsRow,
    SwitchRow,
    clear_layout,
    label,
    page_body,
    page_header,
    page_scroll,
    plain,
    section_label,
    vbox,
    volume_label,
    volume_slider,
    volume_text,
)

#: Executable names are what Windows knows an application by; these are the few
#: whose file name is not what a person calls it.
DISPLAY_NAMES = {
    "Discord.exe": "Discord",
    "chrome.exe": "Chrome",
    "msedge.exe": "Edge",
    "firefox.exe": "Firefox",
    "Spotify.exe": "Spotify",
    "Teams.exe": "Microsoft Teams",
    "ms-teams.exe": "Microsoft Teams",
    "Zoom.exe": "Zoom",
    "WEBRTC VoiceEngine": "Discord (rozmowa)",
}

DISCORD_DEVELOPERS_URL = "https://discord.com/developers/applications"


class SettingsPage(QWidget):
    """Edit supported daemon settings without discarding unknown YAML keys."""

    def __init__(self, on_dirty: Callable[[], None], on_toast: Callable[[str], None]) -> None:
        super().__init__()
        self._on_dirty = on_dirty
        self._on_toast = on_toast
        self._loading = False
        self._audio_refreshing = False
        self._model_options: list[tuple[str, str]] = list(service.MODELS)
        self._muted_apps: list[str] = []
        self._duck_rules: dict[str, float] = {}
        self._detected_audio_apps: dict[str, Any] = {}
        self._duck_app_rows: list[QWidget] = []
        self._rule_widgets: dict[str, tuple[QWidget, QWidget]] = {}

        clamp, self.content = page_body()
        self.content.addWidget(
            page_header("Ustawienia", "Dopasuj model i zachowanie lokalnego dyktowania.")
        )
        self._build_model_group()
        self._build_voice_chat_group()
        self._build_ducking_group()
        self._build_presence_group()
        self._build_behaviour_group()
        self._build_extra_group()
        self.content.addStretch(1)

        outer = QVBoxLayout(self)
        outer.setContentsMargins(0, 0, 0, 0)
        outer.addWidget(page_scroll(clamp))

    # -- group scaffolding ---------------------------------------------------

    def _group(self, title: str, description: str = "") -> tuple[QWidget, SettingsCard]:
        wrapper = plain(vbox(theme.SPACE_12))
        heading = plain(vbox(theme.SPACE_4))
        heading.layout().addWidget(section_label(title))
        if description:
            heading.layout().addWidget(label(description, "secondary-text", wrap=True))
        wrapper.layout().addWidget(heading)
        rows = SettingsCard()
        wrapper.layout().addWidget(rows)
        self.content.addWidget(wrapper)
        return wrapper, rows

    def _combo_row(self, title: str, values: list[str], subtitle: str = "") -> tuple[SettingsRow, Combo]:
        row = SettingsRow(title, subtitle)
        combo = Combo()
        combo.addItems(values)
        combo.setMinimumWidth(220)
        combo.currentIndexChanged.connect(self._changed)
        row.add_suffix(combo)
        return row, combo

    # -- groups --------------------------------------------------------------

    def _build_model_group(self) -> None:
        _wrapper, rows = self._group("Model")
        self.model_row, self.model_combo = self._combo_row(
            "Model rozpoznawania mowy", [name for name, _size in self._model_options]
        )
        self.model_combo.currentIndexChanged.connect(self._update_model_subtitle)
        rows.append(self.model_row)

        self.device_row, self.device_combo = self._combo_row("Urządzenie", list(service.DEVICES))
        rows.append(self.device_row)

        self.compute_row, self.compute_combo = self._combo_row(
            "Precyzja", list(service.COMPUTE_TYPES), "float16 na GPU, int8 na procesorze"
        )
        rows.append(self.compute_row)

        language_row = SettingsRow(
            "Język", "Kod ISO 639-1; puste pole wykrywa język automatycznie"
        )
        self.language_entry = QLineEdit()
        self.language_entry.setMaxLength(2)
        self.language_entry.setFixedWidth(80)
        self.language_entry.textChanged.connect(self._changed)
        language_row.add_suffix(self.language_entry)
        rows.append(language_row)

        beam_row = SettingsRow("Beam size", "Wyżej = dokładniej i wolniej")
        self.beam_spin = QSpinBox()
        self.beam_spin.setRange(1, 10)
        self.beam_spin.setFixedWidth(80)
        self.beam_spin.valueChanged.connect(self._changed)
        beam_row.add_suffix(self.beam_spin)
        rows.append(beam_row)

    def _build_voice_chat_group(self) -> None:
        wrapper, rows = self._group(
            "Czat głosowy",
            "Nazwy aplikacji pochodzą z Core Audio — na Windowsie jest to nazwa "
            "pliku wykonywalnego, np. „Discord.exe”.",
        )
        self.mute_row = SwitchRow("Wyciszaj mikrofon innych aplikacji podczas dyktowania")
        self.mute_row.toggled.connect(self._changed)
        rows.append(self.mute_row)

        self.duck_row = SwitchRow("Przyciszaj dźwięk podczas dyktowania")
        self.duck_row.toggled.connect(self._on_duck_changed)
        rows.append(self.duck_row)

        wrapper.layout().addWidget(section_label("Aplikacje ze słuchem na twój mikrofon"))
        wrapper.layout().addWidget(
            label(
                "Te aplikacje przechwytują dźwięk z mikrofonu. Zaznaczone zostaną "
                "wyciszone na czas dyktowania, żeby rozmówcy nie słyszeli dyktowanego "
                "tekstu. Aplikacje korzystające ze starego MME zamiast WASAPI są dla "
                "systemu niewidoczne i nie da się ich wyciszyć osobno.",
                "section-hint",
                wrap=True,
            )
        )
        self.apps_holder = vbox(theme.SPACE_8)
        wrapper.layout().addLayout(self.apps_holder)

    def _build_ducking_group(self) -> None:
        _wrapper, self.ducking_rows = self._group(
            "Dźwięk podczas dyktowania",
            "Na czas dyktowania każda aplikacja zostaje ściszona do podanej części "
            "swojej obecnej głośności. 100% = nie ściszaj.",
        )
        default_row = SettingsRow(
            "Pozostałe aplikacje (domyślnie)",
            "Ile głośności zostaje, np. 60% = ścisz do 60% obecnego poziomu",
        )
        self.default_duck_scale = volume_slider()
        self.default_duck_value = volume_label()
        self.default_duck_scale.valueChanged.connect(self._on_default_duck_changed)
        default_row.add_suffix(self.default_duck_scale)
        default_row.add_suffix(self.default_duck_value)
        self.ducking_rows.append(default_row)

        refresh_row = SettingsRow(
            "Wykryte aplikacje audio", "Lista sesji odtwarzania i nagrywania Core Audio"
        )
        self.audio_refresh_button = QPushButton()
        self.audio_refresh_button.setObjectName("icon-button")
        self.audio_refresh_button.setIcon(_refresh_icon())
        self.audio_refresh_button.setToolTip("Odśwież aplikacje audio")
        self.audio_refresh_button.clicked.connect(self.refresh_audio_apps)
        refresh_row.add_suffix(self.audio_refresh_button)
        self.ducking_rows.append(refresh_row)

    def _build_presence_group(self) -> None:
        _wrapper, rows = self._group(
            "Discord — status podczas dyktowania",
            "Załóż darmową aplikację na discord.com/developers/applications "
            "(nazwa: voiceflow) i wklej jej Application ID.",
        )
        self.presence_row = SwitchRow("Pokazuj znajomym status podczas dyktowania")
        self.presence_row.toggled.connect(self._changed)
        rows.append(self.presence_row)

        client_row = SettingsRow("Application ID")
        self.client_id_entry = QLineEdit()
        self.client_id_entry.setObjectName("monospace-entry")
        self.client_id_entry.setFixedWidth(240)
        self.client_id_entry.textChanged.connect(self._changed)
        client_row.add_suffix(self.client_id_entry)
        rows.append(client_row)

        link_row = SettingsRow("Panel deweloperski Discorda")
        link = QPushButton("discord.com/developers/applications")
        link.setObjectName("settings-link")
        link.setCursor(Qt.CursorShape.PointingHandCursor)
        link.clicked.connect(lambda: QDesktopServices.openUrl(QUrl(DISCORD_DEVELOPERS_URL)))
        link_row.add_suffix(link)
        rows.append(link_row)

        self.discord_status_row = SettingsRow("")
        rows.append(self.discord_status_row)

    def _build_behaviour_group(self) -> None:
        _wrapper, rows = self._group("Zachowanie")
        self.preview_row = SwitchRow("Podgląd na żywo")
        self.preview_row.toggled.connect(self._changed)
        rows.append(self.preview_row)

        self.overlay_row = SwitchRow("Wskaźnik na ekranie")
        self.overlay_row.toggled.connect(self._changed)
        rows.append(self.overlay_row)

        self.restore_row = SwitchRow("Przywracaj schowek")
        self.restore_row.toggled.connect(self._changed)
        rows.append(self.restore_row)

        paste_row = SettingsRow(
            "Skrót wklejania", "Terminale: ctrl+shift+v, inne aplikacje zwykle ctrl+v"
        )
        self.paste_entry = QLineEdit()
        self.paste_entry.setFixedWidth(160)
        self.paste_entry.textChanged.connect(self._changed)
        paste_row.add_suffix(self.paste_entry)
        rows.append(paste_row)

        hotkey_row = SettingsRow(
            "Skrót dyktowania", "Naciśnij, zacznij mówić, naciśnij ponownie"
        )
        self.hotkey_field = HotkeyField()
        self.hotkey_field.setFixedWidth(420)
        self.hotkey_field.changed.connect(self._changed)
        hotkey_row.add_suffix(self.hotkey_field)
        rows.append(hotkey_row)

    def _build_extra_group(self) -> None:
        _wrapper, rows = self._group(
            "Nagrywanie, historia i aktualizacje",
            "Klucze obecne w config.yaml na obu systemach; okno GTK jeszcze ich nie pokazuje.",
        )
        limit_row = SettingsRow("Limit nagrania", "Po tylu sekundach dyktowanie kończy się samo")
        self.max_seconds_spin = QSpinBox()
        self.max_seconds_spin.setRange(10, 3600)
        self.max_seconds_spin.setSuffix(" s")
        self.max_seconds_spin.setFixedWidth(120)
        self.max_seconds_spin.valueChanged.connect(self._changed)
        limit_row.add_suffix(self.max_seconds_spin)
        rows.append(limit_row)

        interval_row = SettingsRow("Odświeżanie podglądu")
        self.preview_interval = QDoubleSpinBox()
        self.preview_interval.setRange(0.2, 10.0)
        self.preview_interval.setSingleStep(0.1)
        self.preview_interval.setSuffix(" s")
        self.preview_interval.setFixedWidth(120)
        self.preview_interval.valueChanged.connect(self._changed)
        interval_row.add_suffix(self.preview_interval)
        rows.append(interval_row)

        window_row = SettingsRow("Okno audio podglądu")
        self.preview_window = QDoubleSpinBox()
        self.preview_window.setRange(1.0, 120.0)
        self.preview_window.setSuffix(" s")
        self.preview_window.setFixedWidth(120)
        self.preview_window.valueChanged.connect(self._changed)
        window_row.add_suffix(self.preview_window)
        rows.append(window_row)

        self.history_row = SwitchRow("Zapisuj historię dyktowań lokalnie")
        self.history_row.toggled.connect(self._changed)
        rows.append(self.history_row)

        self.store_text_row = SwitchRow("Przechowuj treść (bez tego zostają same liczby)")
        self.store_text_row.toggled.connect(self._changed)
        rows.append(self.store_text_row)

        self.updates_row = SwitchRow("Sprawdzaj raz dziennie, czy jest nowa wersja")
        self.updates_row.toggled.connect(self._changed)
        rows.append(self.updates_row)

        self.notifications_row = SwitchRow("Pokazuj powiadomienia o błędach")
        self.notifications_row.toggled.connect(self._changed)
        rows.append(self.notifications_row)

        # Dotyczy wyłącznie wspólnego pokoju: bez pokoju nic nigdzie nie leci.
        self.share_claude_row = SwitchRow(
            "Pokazuj w pokoju zużycie Claude Code",
            "Tokeny i limity trafiają na tablicę pokoju, nigdzie indziej",
        )
        self.share_claude_row.toggled.connect(self._changed)
        rows.append(self.share_claude_row)

        open_row = SettingsRow("Plik konfiguracyjny", str(service.config_path()))
        open_button = QPushButton("Otwórz")
        open_button.clicked.connect(self._open_config)
        open_row.add_suffix(open_button)
        rows.append(open_row)

    # -- loading and saving --------------------------------------------------

    def load_config(self, config: Mapping[str, Any]) -> None:
        """Populate widgets from a raw configuration mapping without dirtying it."""
        self._loading = True
        try:
            model = service.section(config, "model")
            configured_model = service.string_value(model, "name", "large-v3-turbo")
            names = [name for name, _size in self._model_options]
            if configured_model not in names:
                self._model_options.append((configured_model, "model niestandardowy"))
                self.model_combo.addItem(configured_model)
                names.append(configured_model)
            self.model_combo.setCurrentIndex(names.index(configured_model))
            self._update_model_subtitle()

            device = service.string_value(model, "device", "cuda")
            self.device_combo.setCurrentIndex(
                service.DEVICES.index(device) if device in service.DEVICES else 0
            )
            compute = service.string_value(model, "compute_type", "float16")
            self.compute_combo.setCurrentIndex(
                service.COMPUTE_TYPES.index(compute) if compute in service.COMPUTE_TYPES else 0
            )
            language = model.get("language", "pl")
            self.language_entry.setText(language if isinstance(language, str) else "")
            self.beam_spin.setValue(service.int_value(model, "beam_size", 5))

            hotkey = service.section(config, "hotkey")
            self.hotkey_field.set_value(
                service.string_value(hotkey, "binding", "ctrl+shift+space")
            )

            mute_apps = service.section(config, "mute_apps")
            self.mute_row.set_checked(service.bool_value(mute_apps, "enabled", True))
            self.duck_row.set_checked(service.bool_value(mute_apps, "duck_enabled", True))
            duck_percent = max(
                0.0, min(100.0, service.float_value(mute_apps, "duck_to", 0.6) * 100.0)
            )
            self.default_duck_scale.setValue(int(round(duck_percent)))
            self.default_duck_value.setText(volume_text(duck_percent))
            self._duck_rules = service.float_mapping_value(mute_apps, "duck_rules")
            self._muted_apps = service.string_list_value(mute_apps, "apps")
            self._render_apps()
            self._render_duck_apps()
            self._set_duck_controls_enabled()

            presence = service.section(config, "presence")
            self.presence_row.set_checked(service.bool_value(presence, "enabled", False))
            self.client_id_entry.setText(service.string_value(presence, "client_id", ""))
            self._refresh_discord_status()

            preview = service.section(config, "preview")
            self.preview_row.set_checked(service.bool_value(preview, "enabled", True))
            self.preview_interval.setValue(
                service.float_value(preview, "interval_seconds", 1.0)
            )
            self.preview_window.setValue(service.float_value(preview, "window_seconds", 30.0))

            overlay = service.section(config, "overlay")
            self.overlay_row.set_checked(service.bool_value(overlay, "enabled", True))

            inject = service.section(config, "inject")
            self.restore_row.set_checked(service.bool_value(inject, "restore_clipboard", True))
            self.paste_entry.setText(service.string_value(inject, "paste_key", "ctrl+v"))

            audio = service.section(config, "audio")
            self.max_seconds_spin.setValue(service.int_value(audio, "max_seconds", 300))

            history = service.section(config, "history")
            self.history_row.set_checked(service.bool_value(history, "enabled", True))
            self.store_text_row.set_checked(service.bool_value(history, "store_text", True))
            self.updates_row.set_checked(
                service.bool_value(service.section(config, "updates"), "check", True)
            )
            self.notifications_row.set_checked(
                service.bool_value(service.section(config, "notifications"), "enabled", True)
            )
            self.share_claude_row.set_checked(
                service.bool_value(service.section(config, "room"), "share_claude_usage", True)
            )
        finally:
            self._loading = False

    def apply_to_config(self, config: dict[str, Any]) -> None:
        """Overlay supported settings while preserving all other YAML values."""
        model = service.mutable_section(config, "model")
        model["name"] = self._selected_model()
        model["device"] = self.device_combo.currentText()
        model["compute_type"] = self.compute_combo.currentText()
        language = self.language_entry.text().strip().lower()
        model["language"] = language or None
        model["beam_size"] = self.beam_spin.value()

        service.mutable_section(config, "hotkey")["binding"] = self.hotkey_field.value()

        mute_apps = service.mutable_section(config, "mute_apps")
        mute_apps["enabled"] = self.mute_row.is_checked()
        mute_apps["apps"] = list(self._muted_apps)
        mute_apps["duck_enabled"] = self.duck_row.is_checked()
        mute_apps["duck_to"] = round(self.default_duck_scale.value() / 100.0, 2)
        mute_apps["duck_rules"] = {
            name: round(volume, 2) for name, volume in self._duck_rules.items()
        }

        presence = service.mutable_section(config, "presence")
        presence["enabled"] = self.presence_row.is_checked()
        presence["client_id"] = self.client_id_entry.text().strip()

        preview = service.mutable_section(config, "preview")
        preview["enabled"] = self.preview_row.is_checked()
        preview["interval_seconds"] = round(self.preview_interval.value(), 2)
        preview["window_seconds"] = round(self.preview_window.value(), 2)

        service.mutable_section(config, "overlay")["enabled"] = self.overlay_row.is_checked()
        service.mutable_section(config, "audio")["max_seconds"] = self.max_seconds_spin.value()

        inject = service.mutable_section(config, "inject")
        inject["paste_key"] = self.paste_entry.text().strip() or "ctrl+v"
        inject["restore_clipboard"] = self.restore_row.is_checked()

        history = service.mutable_section(config, "history")
        history["enabled"] = self.history_row.is_checked()
        history["store_text"] = self.store_text_row.is_checked()
        service.mutable_section(config, "updates")["check"] = self.updates_row.is_checked()
        service.mutable_section(config, "notifications")[
            "enabled"
        ] = self.notifications_row.is_checked()
        service.mutable_section(config, "room")[
            "share_claude_usage"
        ] = self.share_claude_row.is_checked()

    # -- runtime diagnostics -------------------------------------------------

    def refresh_runtime_status(self) -> None:
        """Refresh lightweight diagnostics whenever the settings page is entered."""
        self._refresh_discord_status()
        self.refresh_audio_apps()

    def refresh_audio_apps(self) -> None:
        """Discover audio sessions without blocking the UI thread."""
        if self._audio_refreshing:
            return
        self._audio_refreshing = True
        self.audio_refresh_button.setEnabled(False)
        BackgroundCall(
            service.discover_audio_applications,
            self._finish_audio_refresh,
            self._failed_audio_refresh,
        )

    def _finish_audio_refresh(self, applications: object) -> None:
        self._audio_refreshing = False
        self.audio_refresh_button.setEnabled(True)
        if not isinstance(applications, list):
            return
        self._detected_audio_apps = {app.name: app for app in applications}
        self._render_duck_apps()
        self._render_apps()

    def _failed_audio_refresh(self, message: str) -> None:
        self._audio_refreshing = False
        self.audio_refresh_button.setEnabled(True)
        self._on_toast(f"Nie udało się odświeżyć aplikacji audio: {message}")

    def _refresh_discord_status(self) -> None:
        BackgroundCall(service.discord_available, self._apply_discord_status)

    def _apply_discord_status(self, detected: object) -> None:
        self.discord_status_row.set_title(
            "Discord wykryty ✓" if detected else "Nie wykryto uruchomionego Discorda"
        )
        self.discord_status_row.set_inactive(not detected)

    # -- model -----------------------------------------------------------------

    def _selected_model(self) -> str:
        index = self.model_combo.currentIndex()
        return self._model_options[index][0] if 0 <= index < len(self._model_options) else ""

    def _update_model_subtitle(self, *_args: object) -> None:
        index = self.model_combo.currentIndex()
        if 0 <= index < len(self._model_options):
            self.model_row.set_subtitle(
                f"Przybliżony rozmiar pobierania: {self._model_options[index][1]}"
            )

    # -- ducking ---------------------------------------------------------------

    def _on_duck_changed(self, *_args: object) -> None:
        self._set_duck_controls_enabled()
        self._changed()

    def _set_duck_controls_enabled(self) -> None:
        enabled = self.duck_row.is_checked()
        self.default_duck_scale.setEnabled(enabled)
        for scale, _value in self._rule_widgets.values():
            scale.setEnabled(enabled)

    def _on_default_duck_changed(self, percent: int) -> None:
        self.default_duck_value.setText(volume_text(percent))
        if not self._loading:
            # Applications with no rule of their own follow the default, so the
            # sliders that represent them must move with it.
            self._loading = True
            for name, (rule_scale, rule_label) in self._rule_widgets.items():
                if name not in self._duck_rules:
                    rule_scale.setValue(percent)
                    rule_label.setText(volume_text(percent))
            self._loading = False
        self._changed()

    def _on_rule_changed(self, name: str, value_label, percent: int) -> None:
        value_label.setText(volume_text(percent))
        if not self._loading:
            self._duck_rules[name] = round(percent / 100.0, 2)
            self._changed()

    def _remove_duck_rule(self, name: str) -> None:
        self._duck_rules.pop(name, None)
        self._render_duck_apps()
        self._changed()

    # -- microphone muting -----------------------------------------------------

    def _toggle_mute_app(self, name: str, enabled: bool) -> None:
        listed = {item.casefold() for item in self._muted_apps}
        if enabled and name.casefold() not in listed:
            self._muted_apps.append(name)
            self._changed()
        elif not enabled and name.casefold() in listed:
            self._muted_apps = [
                item for item in self._muted_apps if item.casefold() != name.casefold()
            ]
            self._changed()

    def _render_apps(self) -> None:
        """Detected microphone-capturing apps plus remembered ones, as toggles."""
        clear_layout(self.apps_holder)
        capturing = {
            app.name for app in self._detected_audio_apps.values() if getattr(app, "capturing", False)
        }
        names = sorted(capturing | set(self._muted_apps), key=str.casefold)
        card = SettingsCard()
        if not names:
            row = SettingsRow(
                "Nie wykryto aplikacji nagrywających",
                "Dołącz do rozmowy (np. na Discordzie) i odśwież listę.",
            )
            row.set_inactive(True)
            card.append(row)
        for name in names:
            detected = name in capturing
            row = SwitchRow(
                DISPLAY_NAMES.get(name, name),
                "nagrywa teraz" if detected else "zapamiętana · niedziałająca",
            )
            row.set_inactive(not detected)
            row.set_checked(name.casefold() in {item.casefold() for item in self._muted_apps})
            row.toggled.connect(
                lambda checked, value=name: self._toggle_mute_app(value, checked)
            )
            card.append(row)
        self.apps_holder.addWidget(card)

    def _render_duck_apps(self) -> None:
        for row in self._duck_app_rows:
            self.ducking_rows.remove(row)
        self._duck_app_rows.clear()
        self._rule_widgets.clear()

        names = sorted(set(self._detected_audio_apps) | set(self._duck_rules), key=str.casefold)
        if not names:
            row = SettingsRow(
                "Brak aktywnych aplikacji audio", "Uruchom odtwarzanie i odśwież listę."
            )
            row.set_inactive(True)
            self.ducking_rows.append(row)
            self._duck_app_rows.append(row)
            return

        default_percent = self.default_duck_scale.value()
        for name in names:
            detected = self._detected_audio_apps.get(name)
            active = detected is not None
            if detected is not None and getattr(detected, "playing", False):
                state = "gra teraz"
            elif detected is not None:
                state = "połączona"
            else:
                state = "zapamiętana · niedziałająca"
            row = SettingsRow(DISPLAY_NAMES.get(name, name), state)
            row.set_inactive(not active)

            scale = volume_slider()
            percent = self._duck_rules.get(name, default_percent / 100.0) * 100.0
            value = volume_label()
            scale.setValue(int(round(percent)))
            value.setText(volume_text(percent))
            scale.valueChanged.connect(
                lambda changed, current=name, target=value: self._on_rule_changed(
                    current, target, changed
                )
            )
            row.add_suffix(scale)
            row.add_suffix(value)
            if not active and name in self._duck_rules:
                remove = QPushButton()
                remove.setObjectName("icon-button")
                remove.setIcon(_trash_icon())
                remove.setToolTip(f"Usuń regułę dla {name}")
                remove.clicked.connect(
                    lambda _checked=False, current=name: self._remove_duck_rule(current)
                )
                row.add_suffix(remove)
            self.ducking_rows.append(row)
            self._duck_app_rows.append(row)
            self._rule_widgets[name] = (scale, value)
        self._set_duck_controls_enabled()

    # -- plumbing --------------------------------------------------------------

    def _changed(self, *_args: object) -> None:
        if not self._loading:
            self._on_dirty()

    def _open_config(self) -> None:
        try:
            service.open_in_explorer(service.config_path())
        except RuntimeError as exc:
            self._on_toast(str(exc))


def _refresh_icon():
    from voiceflow.gui import icons

    return icons.icon("view-refresh-symbolic", 16, theme.TEXT_SECONDARY_SOLID)


def _trash_icon():
    from voiceflow.gui import icons

    return icons.icon("user-trash-symbolic", 16, theme.TEXT_SECONDARY_SOLID)
