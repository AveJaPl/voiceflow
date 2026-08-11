"""The config.yaml editor.

Edits are held in memory and written in one atomic pass, so a half-finished
form never reaches the daemon. Unknown keys in the file are preserved: this
window is not the only writer, and it must not eat settings it predates.
"""

from __future__ import annotations

from typing import Any

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QCheckBox,
    QComboBox,
    QDoubleSpinBox,
    QFormLayout,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QPushButton,
    QSpinBox,
    QVBoxLayout,
    QWidget,
)

from voiceflow.gui import service
from voiceflow.gui.hotkeyfield import HotkeyField
from voiceflow.gui.widgets import (
    BackgroundCall,
    Card,
    label,
    page_header,
    page_scroll,
)


def _form(card: Card) -> QFormLayout:
    layout = QFormLayout()
    layout.setLabelAlignment(Qt.AlignmentFlag.AlignLeft)
    layout.setFormAlignment(Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignTop)
    layout.setFieldGrowthPolicy(QFormLayout.FieldGrowthPolicy.ExpandingFieldsGrow)
    layout.setHorizontalSpacing(24)
    layout.setVerticalSpacing(12)
    card.body.addLayout(layout)
    return layout


def _hint(text: str) -> QLabel:
    return label(text, name="faint", wrap=True)


class SettingsPage(QWidget):
    """Every daemon setting this window knows how to edit."""

    def __init__(self, window) -> None:
        super().__init__()
        self._window = window
        self._raw: dict[str, Any] = {}
        self._loading = False
        self._dirty = False

        body = QWidget()
        layout = QVBoxLayout(body)
        layout.setContentsMargins(36, 32, 36, 36)
        layout.setSpacing(20)
        layout.addWidget(
            page_header("Ustawienia", "Dopasuj model i zachowanie lokalnego dyktowania.")
        )
        layout.addWidget(self._build_model_card())
        layout.addWidget(self._build_hotkey_card())
        layout.addWidget(self._build_preview_card())
        layout.addWidget(self._build_audio_card())
        layout.addWidget(self._build_presence_card())
        layout.addWidget(self._build_privacy_card())
        layout.addStretch(1)

        outer = QVBoxLayout(self)
        outer.setContentsMargins(0, 0, 0, 0)
        outer.addWidget(page_scroll(body))
        outer.addWidget(self._build_action_bar())

    # -- cards ---------------------------------------------------------------

    def _build_model_card(self) -> Card:
        card = Card()
        card.body.addWidget(label("Model rozpoznawania mowy", name="card-title"))
        form = _form(card)

        self._model = QComboBox()
        for name, size in service.MODELS:
            self._model.addItem(f"{name}  ({size})", name)
        self._model.currentIndexChanged.connect(self._touch)
        form.addRow("Model", self._model)

        self._device = QComboBox()
        self._device.addItems(service.DEVICES)
        self._device.currentIndexChanged.connect(self._touch)
        form.addRow("Urządzenie", self._device)

        self._compute = QComboBox()
        self._compute.addItems(service.COMPUTE_TYPES)
        self._compute.currentIndexChanged.connect(self._touch)
        form.addRow("Precyzja", self._compute)

        self._language = QLineEdit()
        self._language.setPlaceholderText("pl")
        self._language.textChanged.connect(self._touch)
        form.addRow("Język", self._language)
        card.body.addWidget(_hint("Kod ISO 639-1; puste pole wykrywa język automatycznie."))

        self._beam = QSpinBox()
        self._beam.setRange(1, 10)
        self._beam.valueChanged.connect(self._touch)
        form.addRow("Beam size", self._beam)
        return card

    def _build_hotkey_card(self) -> Card:
        card = Card()
        card.body.addWidget(label("Skrót klawiszowy", name="card-title"))
        form = _form(card)
        self._hotkey = HotkeyField()
        self._hotkey.changed.connect(self._touch)
        form.addRow("Skrót", self._hotkey)
        card.body.addWidget(
            _hint(
                "Naciśnij „Nagraj skrót” i wciśnij kombinację — klawisz Windows "
                "też zostanie złapany. Modyfikatory: ctrl, shift, alt, win. "
                "Klawisz: litera, cyfra, space, insert, pause albo f1–f24. "
                "Zapis ustawień restartuje demona, więc skrót działa od razu."
            )
        )

        form2 = _form(card)
        self._paste_key = QLineEdit()
        self._paste_key.setPlaceholderText("ctrl+v")
        self._paste_key.textChanged.connect(self._touch)
        form2.addRow("Skrót wklejania", self._paste_key)
        self._restore_clipboard = QCheckBox("Przywracaj poprzedni schowek po wklejeniu")
        self._restore_clipboard.toggled.connect(self._touch)
        card.body.addWidget(self._restore_clipboard)
        card.body.addWidget(
            _hint(
                "Większość aplikacji Windows wkleja przez ctrl+v; terminale "
                "często wymagają ctrl+shift+v."
            )
        )
        return card

    def _build_preview_card(self) -> Card:
        card = Card()
        card.body.addWidget(label("Podgląd na żywo", name="card-title"))
        self._preview_enabled = QCheckBox("Pokazuj tekst na bieżąco podczas mówienia")
        self._preview_enabled.toggled.connect(self._touch)
        card.body.addWidget(self._preview_enabled)

        form = _form(card)
        self._preview_interval = QDoubleSpinBox()
        self._preview_interval.setRange(0.2, 10.0)
        self._preview_interval.setSingleStep(0.1)
        self._preview_interval.setSuffix(" s")
        self._preview_interval.valueChanged.connect(self._touch)
        form.addRow("Odświeżanie", self._preview_interval)

        self._preview_window = QDoubleSpinBox()
        self._preview_window.setRange(1.0, 120.0)
        self._preview_window.setSuffix(" s")
        self._preview_window.valueChanged.connect(self._touch)
        form.addRow("Okno audio", self._preview_window)

        self._overlay_enabled = QCheckBox("Pokazuj wskaźnik nagrywania na ekranie")
        self._overlay_enabled.toggled.connect(self._touch)
        card.body.addWidget(self._overlay_enabled)
        return card

    def _build_audio_card(self) -> Card:
        card = Card()
        card.body.addWidget(label("Dźwięk podczas dyktowania", name="card-title"))
        self._duck_enabled = QCheckBox("Przyciszaj inne aplikacje, kiedy mówisz")
        self._duck_enabled.toggled.connect(self._touch)
        card.body.addWidget(self._duck_enabled)

        form = _form(card)
        self._mute_apps = QLineEdit()
        self._mute_apps.setPlaceholderText("Discord.exe, Teams.exe")
        self._mute_apps.textChanged.connect(self._touch)
        form.addRow("Wycisz mikrofon w", self._mute_apps)

        self._duck_volume = QSpinBox()
        self._duck_volume.setRange(0, 100)
        self._duck_volume.setSuffix(" %")
        self._duck_volume.valueChanged.connect(self._touch)
        form.addRow("Głośność", self._duck_volume)

        self._max_seconds = QSpinBox()
        self._max_seconds.setRange(10, 3600)
        self._max_seconds.setSuffix(" s")
        self._max_seconds.valueChanged.connect(self._touch)
        form.addRow("Limit nagrania", self._max_seconds)

        header = QHBoxLayout()
        header.addWidget(label("Wykryte aplikacje audio", name="section-label"))
        header.addStretch(1)
        refresh = QPushButton("Odśwież")
        refresh.setObjectName("ghost")
        refresh.clicked.connect(self._refresh_audio)
        header.addWidget(refresh)
        card.body.addLayout(header)

        self._audio_list = label("Sprawdzanie…", name="faint", wrap=True)
        card.body.addWidget(self._audio_list)
        card.body.addWidget(
            _hint(
                "Aplikacje po przecinku — ich mikrofon jest wyciszany na czas "
                "dyktowania, więc rozmówcy nie słyszą promptu, a voiceflow "
                "nagrywa dalej. Po nagraniu wszystko wraca do poprzedniego "
                "stanu. Oznaczone 🎤 właśnie nagrywają, ● odtwarzają. Aplikacje "
                "korzystające ze starego MME zamiast WASAPI są niewidoczne dla "
                "systemu i nie da się ich wyciszyć osobno."
            )
        )
        return card

    def _build_presence_card(self) -> Card:
        card = Card()
        card.body.addWidget(label("Discord — status podczas dyktowania", name="card-title"))
        self._presence_enabled = QCheckBox("Pokazuj znajomym status podczas dyktowania")
        self._presence_enabled.toggled.connect(self._touch)
        card.body.addWidget(self._presence_enabled)

        form = _form(card)
        self._presence_id = QLineEdit()
        self._presence_id.setPlaceholderText("Application ID z discord.com/developers")
        self._presence_id.textChanged.connect(self._touch)
        form.addRow("Application ID", self._presence_id)

        self._discord_state = label("", name="faint")
        card.body.addWidget(self._discord_state)
        return card

    def _build_privacy_card(self) -> Card:
        card = Card()
        card.body.addWidget(label("Prywatność i aktualizacje", name="card-title"))
        self._history_enabled = QCheckBox("Zapisuj historię dyktowań lokalnie")
        self._history_enabled.toggled.connect(self._touch)
        card.body.addWidget(self._history_enabled)

        self._store_text = QCheckBox("Przechowuj treść (bez tego zostają same liczby)")
        self._store_text.toggled.connect(self._touch)
        card.body.addWidget(self._store_text)

        self._updates = QCheckBox("Sprawdzaj raz dziennie, czy jest nowa wersja")
        self._updates.toggled.connect(self._touch)
        card.body.addWidget(self._updates)

        self._notifications = QCheckBox("Pokazuj powiadomienia o błędach")
        self._notifications.toggled.connect(self._touch)
        card.body.addWidget(self._notifications)

        card.body.addWidget(
            _hint(
                "Sprawdzanie aktualizacji to jedyne zapytanie sieciowe, jakie "
                "wykonuje voiceflow. Nagrania i tekst nigdy nie opuszczają "
                "tego komputera."
            )
        )
        return card

    def _build_action_bar(self) -> QWidget:
        bar = QWidget()
        layout = QHBoxLayout(bar)
        layout.setContentsMargins(36, 12, 36, 20)
        layout.setSpacing(12)
        self._status = label("", name="faint")
        layout.addWidget(self._status)
        layout.addStretch(1)

        open_file = QPushButton("Otwórz config.yaml")
        open_file.setObjectName("ghost")
        open_file.clicked.connect(self._open_config)
        layout.addWidget(open_file)

        self._revert = QPushButton("Odrzuć zmiany")
        self._revert.setEnabled(False)
        self._revert.clicked.connect(self.refresh)
        layout.addWidget(self._revert)

        self._save = QPushButton("Zapisz i uruchom ponownie")
        self._save.setObjectName("primary")
        self._save.setEnabled(False)
        self._save.clicked.connect(self._save_config)
        layout.addWidget(self._save)
        return bar

    # -- loading and saving --------------------------------------------------

    def refresh(self) -> None:
        BackgroundCall(service.load_raw_config, self._apply, self._failed)
        self._refresh_audio()
        BackgroundCall(service.discord_available, self._apply_discord)

    def _failed(self, message: str) -> None:
        self._window.notify(message, tone="error")

    def _apply(self, raw: object) -> None:
        if not isinstance(raw, dict):
            return
        self._raw = raw
        self._loading = True
        try:
            model = service.section(raw, "model")
            self._select(self._model, service.string_value(model, "name", "large-v3-turbo"))
            self._select_text(self._device, service.string_value(model, "device", "cuda"))
            self._select_text(self._compute, service.string_value(model, "compute_type", "float16"))
            language = model.get("language")
            self._language.setText(language if isinstance(language, str) else "")
            self._beam.setValue(service.int_value(model, "beam_size", 5))

            hotkey = service.section(raw, "hotkey")
            self._hotkey.set_value(service.string_value(hotkey, "binding", "ctrl+shift+space"))

            inject = service.section(raw, "inject")
            self._paste_key.setText(service.string_value(inject, "paste_key", "ctrl+v"))
            self._restore_clipboard.setChecked(
                service.bool_value(inject, "restore_clipboard", True)
            )

            preview = service.section(raw, "preview")
            self._preview_enabled.setChecked(service.bool_value(preview, "enabled", True))
            self._preview_interval.setValue(service.float_value(preview, "interval_seconds", 1.0))
            self._preview_window.setValue(service.float_value(preview, "window_seconds", 30.0))

            overlay = service.section(raw, "overlay")
            self._overlay_enabled.setChecked(service.bool_value(overlay, "enabled", True))

            audio = service.section(raw, "audio")
            self._max_seconds.setValue(service.int_value(audio, "max_seconds", 300))

            mute = service.section(raw, "mute_apps")
            self._mute_apps.setText(", ".join(service.string_list_value(mute, "apps")))
            self._duck_enabled.setChecked(service.bool_value(mute, "duck_enabled", True))
            self._duck_volume.setValue(int(service.float_value(mute, "duck_volume", 0.4) * 100))

            presence = service.section(raw, "presence")
            self._presence_enabled.setChecked(service.bool_value(presence, "enabled", False))
            self._presence_id.setText(service.string_value(presence, "client_id", ""))

            history = service.section(raw, "history")
            self._history_enabled.setChecked(service.bool_value(history, "enabled", True))
            self._store_text.setChecked(service.bool_value(history, "store_text", True))

            updates = service.section(raw, "updates")
            self._updates.setChecked(service.bool_value(updates, "check", True))

            notifications = service.section(raw, "notifications")
            self._notifications.setChecked(service.bool_value(notifications, "enabled", True))
        finally:
            self._loading = False
        self._set_dirty(False)

    @staticmethod
    def _select(combo: QComboBox, value: str) -> None:
        index = combo.findData(value)
        if index < 0:
            combo.addItem(value, value)
            index = combo.count() - 1
        combo.setCurrentIndex(index)

    @staticmethod
    def _select_text(combo: QComboBox, value: str) -> None:
        index = combo.findText(value)
        if index < 0:
            combo.addItem(value)
            index = combo.count() - 1
        combo.setCurrentIndex(index)

    def _touch(self, *_args: object) -> None:
        if not self._loading:
            self._set_dirty(True)

    def _set_dirty(self, dirty: bool) -> None:
        self._dirty = dirty
        self._save.setEnabled(dirty)
        self._revert.setEnabled(dirty)
        self._status.setText("Masz niezapisane zmiany." if dirty else "")

    def _apply_edits(self, raw: dict[str, Any]) -> None:
        """Overlay this page's fields onto a freshly read mapping.

        Only the keys this page owns are touched, so the vocabulary page's
        terms and anything hand-edited in the file survive a save.
        """
        model = service.mutable_section(raw, "model")
        model["name"] = self._model.currentData()
        model["device"] = self._device.currentText()
        model["compute_type"] = self._compute.currentText()
        language = self._language.text().strip()
        model["language"] = language or None
        model["beam_size"] = self._beam.value()

        service.mutable_section(raw, "hotkey")["binding"] = self._hotkey.value()

        inject = service.mutable_section(raw, "inject")
        inject["paste_key"] = self._paste_key.text().strip() or "ctrl+v"
        inject["restore_clipboard"] = self._restore_clipboard.isChecked()

        preview = service.mutable_section(raw, "preview")
        preview["enabled"] = self._preview_enabled.isChecked()
        preview["interval_seconds"] = round(self._preview_interval.value(), 2)
        preview["window_seconds"] = round(self._preview_window.value(), 2)

        service.mutable_section(raw, "overlay")["enabled"] = self._overlay_enabled.isChecked()
        service.mutable_section(raw, "audio")["max_seconds"] = self._max_seconds.value()

        mute = service.mutable_section(raw, "mute_apps")
        mute["apps"] = [name.strip() for name in self._mute_apps.text().split(",") if name.strip()]
        mute["duck_enabled"] = self._duck_enabled.isChecked()
        mute["duck_volume"] = round(self._duck_volume.value() / 100, 2)

        presence = service.mutable_section(raw, "presence")
        presence["enabled"] = self._presence_enabled.isChecked()
        presence["client_id"] = self._presence_id.text().strip()

        history = service.mutable_section(raw, "history")
        history["enabled"] = self._history_enabled.isChecked()
        history["store_text"] = self._store_text.isChecked()

        service.mutable_section(raw, "updates")["check"] = self._updates.isChecked()
        service.mutable_section(raw, "notifications")[
            "enabled"
        ] = self._notifications.isChecked()

    def _save_config(self) -> None:
        self._save.setEnabled(False)
        self._status.setText("Zapisywanie i restart demona…")

        def work() -> dict[str, Any]:
            written = service.update_config(self._apply_edits)
            # The daemon reads config once at startup, so a saved setting that
            # does not restart it is a setting that silently did not apply.
            if service.daemon_status() is not None:
                service.restart_daemon()
            return written

        def done(written: object) -> None:
            if isinstance(written, dict):
                self._raw = written
            self._set_dirty(False)
            self._window.notify("Zapisano — demon uruchomiony ponownie")
            self._window.refresh_current()

        def failed(message: str) -> None:
            self._save.setEnabled(True)
            self._status.setText("")
            self._window.notify(message, tone="error")

        BackgroundCall(work, done, failed)

    def _open_config(self) -> None:
        try:
            service.open_in_explorer(service.config_path())
        except RuntimeError as exc:
            self._window.notify(str(exc), tone="error")

    def _refresh_audio(self) -> None:
        BackgroundCall(service.discover_audio_applications, self._apply_audio, self._failed)

    def _apply_audio(self, applications: object) -> None:
        if not isinstance(applications, list) or not applications:
            self._audio_list.setText("Nie wykryto aplikacji odtwarzających dźwięk.")
            return
        names = [
            f"{application.name}"
            f"{' 🎤' if application.capturing else ''}"
            f"{' ●' if application.playing else ''}"
            for application in applications
        ]
        self._audio_list.setText("   ".join(names))

    def _apply_discord(self, available: object) -> None:
        self._discord_state.setText(
            "Discord wykryty ✓" if available else "Nie wykryto uruchomionego Discorda."
        )
