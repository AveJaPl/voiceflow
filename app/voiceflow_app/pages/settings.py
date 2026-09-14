"""Configuration editor presented as matte application cards."""

from __future__ import annotations

import threading
from collections.abc import Callable, Mapping
from pathlib import Path
from typing import Any

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gdk, GLib, Gtk  # noqa: E402

from voiceflow_app import services, shortcuts, style
from voiceflow_app.pages.common import label, page_content, page_header
from voiceflow_app.services import (
    DEVICES,
    MODELS,
    bool_value,
    ensure_mutable_section,
    float_mapping_value,
    float_value,
    section,
    string_list_value,
    string_value,
)


#: Fallback when GNOME has no voiceflow binding yet; matches install-hotkey.sh.
DEFAULT_HOTKEY = "<Super>g"
#: What the shortcut runs. The wrapper in ~/.local/bin is what the installer
#: creates, and it is on PATH for the session that fires the key.
HOTKEY_COMMAND = str(Path.home() / ".local" / "bin" / "voiceflow") + " toggle"

DISPLAY_NAMES = {
    "WEBRTC VoiceEngine": "Discord (rozmowa)",
    "Chromium": "Chrome",
    "Google Chrome": "Chrome",
    "Firefox": "Firefox",
    "Spotify": "Spotify",
}


class SettingsPage(Gtk.ScrolledWindow):
    """Edit supported daemon settings without discarding unknown YAML keys."""

    def __init__(
        self, on_dirty: Callable[[], None], on_toast: Callable[[str], None]
    ) -> None:
        super().__init__(hscrollbar_policy=Gtk.PolicyType.NEVER)
        self.add_css_class("page-scroll")
        self._on_dirty = on_dirty
        self._on_toast = on_toast
        self._loading = False
        self._audio_refreshing = False
        self._model_options: list[tuple[str, str]] = list(MODELS)
        self._muted_apps: list[str] = []
        self._duck_rules: dict[str, float] = {}
        self._detected_audio_apps: dict[str, services.AudioApplication] = {}
        self._duck_app_rows: list[Gtk.ListBoxRow] = []
        self._rule_widgets: dict[str, tuple[Gtk.Scale, Gtk.Label]] = {}

        self.content = page_content(self)
        self.content.append(
            page_header(
                "Ustawienia",
                "Dopasuj model i zachowanie lokalnego dyktowania.",
            )
        )

        self._build_model_group()
        self._build_voice_chat_group()
        self._build_ducking_group()
        self._build_presence_group()
        self._build_behaviour_group()

    def _group(
        self, title: str, description: str | None = None
    ) -> tuple[Gtk.Box, Gtk.ListBox]:
        wrapper = Gtk.Box(
            orientation=Gtk.Orientation.VERTICAL,
            spacing=style.SPACE_12,
        )
        heading = Gtk.Box(
            orientation=Gtk.Orientation.VERTICAL,
            spacing=style.SPACE_4,
        )
        heading.append(label(title.upper(), "section-label"))
        if description:
            description_label = label(description, "secondary-text")
            description_label.set_wrap(True)
            heading.append(description_label)
        wrapper.append(heading)
        rows = Gtk.ListBox(selection_mode=Gtk.SelectionMode.NONE)
        rows.add_css_class("card")
        rows.add_css_class("settings-card")
        wrapper.append(rows)
        self.content.append(wrapper)
        return wrapper, rows

    def _build_model_group(self) -> None:
        _wrapper, rows = self._group("Model")
        self.model_row = Adw.ComboRow(
            title="Model rozpoznawania mowy",
            model=Gtk.StringList.new([name for name, _size in self._model_options]),
        )
        self.model_row.connect("notify::selected", self._on_model_selected)
        rows.append(self.model_row)

        self.device_row = Adw.ComboRow(
            title="Urządzenie", model=Gtk.StringList.new(list(DEVICES))
        )
        self.device_row.connect("notify::selected", self._changed)
        rows.append(self.device_row)

        language_row = Adw.ActionRow(
            title="Język",
            subtitle="Kod ISO 639-1; puste pole wykrywa język automatycznie",
        )
        self.language_entry = Gtk.Entry(width_chars=8, max_length=2)
        self.language_entry.add_css_class("flat-entry")
        self.language_entry.set_valign(Gtk.Align.CENTER)
        self.language_entry.connect("changed", self._changed)
        language_row.add_suffix(self.language_entry)
        rows.append(language_row)

    def _build_voice_chat_group(self) -> None:
        wrapper, rows = self._group(
            "Czat głosowy",
            "Nazwy aplikacji pochodzą z PipeWire. „WEBRTC VoiceEngine” to "
            "strumień mikrofonu Discorda.",
        )
        self.mute_row = Adw.SwitchRow(
            title="Wyciszaj mikrofon innych aplikacji podczas dyktowania"
        )
        self.mute_row.connect("notify::active", self._changed)
        rows.append(self.mute_row)

        self.duck_row = Adw.SwitchRow(title="Przyciszaj dźwięk podczas dyktowania")
        self.duck_row.connect("notify::active", self._on_duck_changed)
        rows.append(self.duck_row)

        wrapper.append(label("APLIKACJE ZE SŁUCHEM NA TWÓJ MIKROFON", "section-label"))
        hint = label(
            "Te aplikacje przechwytują dźwięk z mikrofonu. Zaznaczone zostaną "
            "wyciszone na czas dyktowania, żeby rozmówcy nie słyszeli dyktowanego tekstu.",
            "section-hint",
        )
        hint.set_wrap(True)
        hint.set_xalign(0.0)
        wrapper.append(hint)
        self.apps_holder = Gtk.Box(
            orientation=Gtk.Orientation.VERTICAL, spacing=style.SPACE_8
        )
        wrapper.append(self.apps_holder)

    def _build_ducking_group(self) -> None:
        _wrapper, self.ducking_rows = self._group(
            "Dźwięk podczas dyktowania",
            "Na czas dyktowania każda aplikacja zostaje ściszona do podanej "
            "części swojej obecnej głośności. 100% = nie ściszaj.",
        )
        default_row = Adw.ActionRow(
            title="Pozostałe aplikacje (domyślnie)",
            subtitle="Ile głośności zostaje, np. 60% = ścisz do 60% obecnego poziomu",
        )
        self.default_duck_scale = self._volume_scale()
        self.default_duck_value = self._volume_label()
        self.default_duck_scale.connect("value-changed", self._on_default_duck_changed)
        default_row.add_suffix(self.default_duck_scale)
        default_row.add_suffix(self.default_duck_value)
        self.ducking_rows.append(default_row)

        refresh_row = Adw.ActionRow(
            title="Wykryte aplikacje audio",
            subtitle="Lista aktywnych strumieni odtwarzania PipeWire",
        )
        self.audio_refresh_button = Gtk.Button(icon_name="view-refresh-symbolic")
        self.audio_refresh_button.add_css_class("icon-button")
        self.audio_refresh_button.set_tooltip_text("Odśwież aplikacje audio")
        self.audio_refresh_button.connect(
            "clicked", lambda _button: self.refresh_audio_apps()
        )
        refresh_row.add_suffix(self.audio_refresh_button)
        self.ducking_rows.append(refresh_row)

    def _build_presence_group(self) -> None:
        _wrapper, rows = self._group(
            "Discord — status podczas dyktowania",
            "Załóż darmową aplikację na discord.com/developers/applications "
            "(nazwa: voiceflow) i wklej jej Application ID.",
        )
        self.presence_row = Adw.SwitchRow(
            title="Pokazuj znajomym status podczas dyktowania"
        )
        self.presence_row.connect("notify::active", self._changed)
        rows.append(self.presence_row)

        client_row = Adw.ActionRow(title="Application ID")
        self.client_id_entry = Gtk.Entry(width_chars=22)
        self.client_id_entry.add_css_class("flat-entry")
        self.client_id_entry.add_css_class("monospace-entry")
        self.client_id_entry.set_valign(Gtk.Align.CENTER)
        self.client_id_entry.connect("changed", self._changed)
        client_row.add_suffix(self.client_id_entry)
        rows.append(client_row)

        link_row = Adw.ActionRow(title="Panel deweloperski Discorda")
        link = Gtk.LinkButton(
            uri="https://discord.com/developers/applications",
            label="discord.com/developers/applications",
        )
        link.add_css_class("settings-link")
        link_row.add_suffix(link)
        rows.append(link_row)

        self.discord_status_row = Adw.ActionRow()
        rows.append(self.discord_status_row)

    def _build_behaviour_group(self) -> None:
        _wrapper, rows = self._group("Zachowanie")
        self.preview_row = Adw.SwitchRow(title="Podgląd na żywo")
        self.preview_row.connect("notify::active", self._changed)
        rows.append(self.preview_row)

        self.overlay_row = Adw.SwitchRow(title="Wskaźnik na ekranie")
        self.overlay_row.connect("notify::active", self._changed)
        rows.append(self.overlay_row)

        self.restore_row = Adw.SwitchRow(title="Przywracaj schowek")
        self.restore_row.connect("notify::active", self._changed)
        rows.append(self.restore_row)

        paste_row = Adw.ActionRow(
            title="Skrót wklejania",
            subtitle="Terminale: ctrl+shift+v, inne aplikacje zwykle ctrl+v",
        )
        self.paste_entry = Gtk.Entry(width_chars=15)
        self.paste_entry.add_css_class("flat-entry")
        self.paste_entry.set_valign(Gtk.Align.CENTER)
        self.paste_entry.connect("changed", self._changed)
        paste_row.add_suffix(self.paste_entry)
        rows.append(paste_row)

        self.hotkey_row = Adw.ActionRow(
            title="Skrót dyktowania",
            subtitle="Naciśnij, zacznij mówić, naciśnij ponownie",
        )
        self.hotkey_label = Gtk.ShortcutLabel(accelerator=self._current_hotkey())
        self.hotkey_label.set_valign(Gtk.Align.CENTER)
        change_button = Gtk.Button(label="Zmień")
        change_button.set_valign(Gtk.Align.CENTER)
        change_button.connect("clicked", self._on_change_hotkey)
        self.hotkey_row.add_suffix(self.hotkey_label)
        self.hotkey_row.add_suffix(change_button)
        rows.append(self.hotkey_row)

    # -- dictation shortcut ------------------------------------------------

    def _current_hotkey(self) -> str:
        try:
            return shortcuts.current_binding() or DEFAULT_HOTKEY
        except Exception:  # pragma: no cover - depends on a live gsettings
            return DEFAULT_HOTKEY

    def _on_change_hotkey(self, _button: Gtk.Button) -> None:
        dialog = Adw.AlertDialog(
            heading="Naciśnij nowy skrót",
            body=(
                "Przytrzymaj modyfikatory i naciśnij klawisz.\n"
                "Esc anuluje, Backspace przywraca domyślny."
            ),
        )
        dialog.add_response("cancel", "Anuluj")
        dialog.set_default_response("cancel")
        controller = Gtk.EventControllerKey()
        controller.connect("key-pressed", self._on_hotkey_captured, dialog)
        dialog.add_controller(controller)
        # While this is open the desktop must stop swallowing its own shortcuts,
        # or the combinations most worth rebinding — the ones already taken —
        # would fire their existing action instead of reaching this handler.
        # Pressing <Super>g would start a dictation rather than be captured.
        toplevel = self._toplevel_surface()
        if toplevel is not None:
            toplevel.inhibit_system_shortcuts(None)
        dialog.connect("closed", self._on_capture_closed)
        dialog.present(self)

    def _toplevel_surface(self) -> Any:
        root = self.get_root()
        surface = root.get_surface() if root is not None else None
        return surface if surface is not None and hasattr(surface, "inhibit_system_shortcuts") else None

    def _on_capture_closed(self, _dialog: Adw.AlertDialog) -> None:
        toplevel = self._toplevel_surface()
        if toplevel is not None:
            toplevel.restore_system_shortcuts()

    def _on_hotkey_captured(
        self,
        _controller: Gtk.EventControllerKey,
        keyval: int,
        _keycode: int,
        state: Gdk.ModifierType,
        dialog: Adw.AlertDialog,
    ) -> bool:
        modifiers = state & Gtk.accelerator_get_default_mod_mask()
        if keyval == Gdk.KEY_Escape and not modifiers:
            dialog.close()
            return True
        if keyval == Gdk.KEY_BackSpace and not modifiers:
            dialog.close()
            self._confirm_hotkey(DEFAULT_HOTKEY)
            return True
        if not Gtk.accelerator_valid(keyval, modifiers):
            # A bare modifier, or a key the desktop will not accept as a
            # shortcut. Keep waiting rather than closing on a half-press.
            return True
        accelerator = Gtk.accelerator_name(keyval, modifiers)
        dialog.close()
        if accelerator:
            self._confirm_hotkey(accelerator)
        return True

    def _confirm_hotkey(self, accelerator: str) -> None:
        """Apply the new key, asking first when something else already owns it."""
        try:
            taken = shortcuts.conflicts(accelerator, shortcuts.scan())
        except Exception as error:  # pragma: no cover - depends on live gsettings
            self._on_toast(f"Nie udało się sprawdzić kolizji skrótów: {error}")
            taken = []
        if not taken:
            self._write_hotkey(accelerator)
            return
        dialog = Adw.AlertDialog(
            heading="Ten skrót jest już zajęty",
            body=(
                f"„{shortcuts.describe(taken)}” już reaguje na tę kombinację.\n\n"
                "Jeśli ustawisz ją mimo to, oba działania będą nasłuchiwać tego "
                "samego klawisza — zwykle wygrywa pulpit, więc dyktowanie może "
                "się w ogóle nie uruchamiać."
            ),
        )
        dialog.add_response("cancel", "Wybierz inny")
        dialog.add_response("replace", "Ustaw mimo to")
        dialog.set_response_appearance("replace", Adw.ResponseAppearance.DESTRUCTIVE)
        dialog.set_default_response("cancel")
        dialog.connect("response", self._on_conflict_response, accelerator)
        dialog.present(self)

    def _on_conflict_response(
        self, _dialog: Adw.AlertDialog, response: str, accelerator: str
    ) -> None:
        if response == "replace":
            self._write_hotkey(accelerator)

    def _write_hotkey(self, accelerator: str) -> None:
        try:
            shortcuts.apply_binding(accelerator, HOTKEY_COMMAND)
        except Exception as error:  # pragma: no cover - depends on live gsettings
            self._on_toast(f"Nie udało się zapisać skrótu: {error}")
            return
        self.hotkey_label.set_accelerator(accelerator)
        self._on_toast("Skrót dyktowania zmieniony")

    @staticmethod
    def _volume_scale() -> Gtk.Scale:
        scale = Gtk.Scale.new_with_range(Gtk.Orientation.HORIZONTAL, 0.0, 100.0, 1.0)
        scale.set_draw_value(False)
        scale.set_size_request(176, -1)
        scale.set_valign(Gtk.Align.CENTER)
        return scale

    @staticmethod
    def _volume_label() -> Gtk.Label:
        value = label("0%", "volume-value")
        value.set_width_chars(14)
        value.set_xalign(1)
        return value

    @staticmethod
    def _volume_text(percent: float) -> str:
        """Label the slider as what it is: a share of the app's own volume."""
        rounded = int(round(percent))
        if rounded == 100:
            return "100% · nie ściszaj"
        return f"{rounded}% obecnej"

    def load_config(self, config: Mapping[str, Any]) -> None:
        """Populate widgets from a raw configuration mapping without dirtying it."""
        self._loading = True
        model = section(config, "model")
        configured_model = string_value(model, "name", "large-v3-turbo")
        names = [name for name, _size in self._model_options]
        if configured_model not in names:
            self._model_options.append((configured_model, "model niestandardowy"))
            names.append(configured_model)
            self.model_row.set_model(Gtk.StringList.new(names))
        self.model_row.set_selected(names.index(configured_model))
        self._update_model_subtitle()

        device = string_value(model, "device", "cuda")
        self.device_row.set_selected(DEVICES.index(device) if device in DEVICES else 0)
        language = model.get("language", "pl")
        self.language_entry.set_text(language if isinstance(language, str) else "")

        mute_apps = section(config, "mute_apps")
        self.mute_row.set_active(bool_value(mute_apps, "enabled", True))
        self.duck_row.set_active(bool_value(mute_apps, "duck_enabled", True))
        duck_percent = max(
            0.0, min(100.0, float_value(mute_apps, "duck_to", 0.6) * 100.0)
        )
        self.default_duck_scale.set_value(duck_percent)
        self.default_duck_value.set_label(self._volume_text(duck_percent))
        self._duck_rules = float_mapping_value(mute_apps, "duck_rules")
        self._muted_apps = string_list_value(
            mute_apps, "apps", ["WEBRTC VoiceEngine"]
        )
        self._render_apps()
        self._render_duck_apps()
        self._set_duck_controls_sensitive()

        presence = section(config, "presence")
        self.presence_row.set_active(bool_value(presence, "enabled", False))
        client_id = presence.get("client_id", "")
        self.client_id_entry.set_text(str(client_id or ""))
        self._refresh_discord_status()

        self.preview_row.set_active(bool_value(section(config, "preview"), "enabled", True))
        self.overlay_row.set_active(bool_value(section(config, "overlay"), "enabled", True))
        inject = section(config, "inject")
        self.restore_row.set_active(bool_value(inject, "restore_clipboard", True))
        self.paste_entry.set_text(string_value(inject, "paste_key", "ctrl+shift+v"))
        self._loading = False

    def apply_to_config(self, config: dict[str, Any]) -> None:
        """Overlay supported settings while preserving all other YAML values."""
        model = ensure_mutable_section(config, "model")
        model["name"] = self._selected_model()
        model["device"] = DEVICES[self.device_row.get_selected()]
        language = self.language_entry.get_text().strip().lower()
        model["language"] = language or None

        mute_apps = ensure_mutable_section(config, "mute_apps")
        mute_apps["enabled"] = self.mute_row.get_active()
        mute_apps["apps"] = list(self._muted_apps)
        mute_apps["duck_enabled"] = self.duck_row.get_active()
        mute_apps["duck_to"] = round(
            self.default_duck_scale.get_value() / 100.0, 2
        )
        mute_apps["duck_rules"] = {
            name: round(volume, 2) for name, volume in self._duck_rules.items()
        }

        presence = ensure_mutable_section(config, "presence")
        presence["enabled"] = self.presence_row.get_active()
        presence["client_id"] = self.client_id_entry.get_text().strip()

        ensure_mutable_section(config, "preview")["enabled"] = self.preview_row.get_active()
        ensure_mutable_section(config, "overlay")["enabled"] = self.overlay_row.get_active()
        inject = ensure_mutable_section(config, "inject")
        inject["paste_key"] = self.paste_entry.get_text().strip() or "ctrl+shift+v"
        inject["restore_clipboard"] = self.restore_row.get_active()

    def refresh_runtime_status(self) -> None:
        """Refresh lightweight diagnostics whenever the settings page is entered."""
        self._refresh_discord_status()
        self.refresh_audio_apps()

    def refresh_audio_apps(self) -> None:
        """Discover playback streams without blocking the GTK main loop."""
        if self._audio_refreshing:
            return
        self._audio_refreshing = True
        self.audio_refresh_button.set_sensitive(False)

        def worker() -> None:
            try:
                names = services.discover_audio_applications()
            except RuntimeError as exc:
                GLib.idle_add(self._finish_audio_refresh, None, str(exc))
                return
            GLib.idle_add(self._finish_audio_refresh, names, "")

        threading.Thread(target=worker, name="audio-app-discovery", daemon=True).start()

    def _finish_audio_refresh(
        self, names: list[str] | None, error: str
    ) -> bool:
        self._audio_refreshing = False
        self.audio_refresh_button.set_sensitive(True)
        if names is None:
            self._on_toast(f"Nie udało się odświeżyć aplikacji audio: {error}")
        else:
            self._detected_audio_apps = {app.name: app for app in names}
            self._render_duck_apps()
            self._render_apps()
        return GLib.SOURCE_REMOVE

    def _refresh_discord_status(self) -> None:
        detected = services.discord_socket_available()
        self.discord_status_row.set_title(
            "Discord wykryty ✓" if detected else "Nie wykryto uruchomionego Discorda"
        )
        self.discord_status_row.remove_css_class("detected")
        self.discord_status_row.remove_css_class("inactive")
        self.discord_status_row.add_css_class("detected" if detected else "inactive")

    def _selected_model(self) -> str:
        selected = self.model_row.get_selected()
        return self._model_options[selected][0]

    def _on_model_selected(self, *_args: object) -> None:
        self._update_model_subtitle()
        self._changed()

    def _update_model_subtitle(self) -> None:
        selected = self.model_row.get_selected()
        if selected < len(self._model_options):
            self.model_row.set_subtitle(
                f"Przybliżony rozmiar pobierania: {self._model_options[selected][1]}"
            )

    def _on_duck_changed(self, *_args: object) -> None:
        self._set_duck_controls_sensitive()
        self._changed()

    def _set_duck_controls_sensitive(self) -> None:
        sensitive = self.duck_row.get_active()
        self.default_duck_scale.set_sensitive(sensitive)
        for scale, _value in self._rule_widgets.values():
            scale.set_sensitive(sensitive)

    def _on_default_duck_changed(self, scale: Gtk.Scale) -> None:
        percent = scale.get_value()
        self.default_duck_value.set_label(self._volume_text(percent))
        if not self._loading:
            self._loading = True
            for name, (rule_scale, rule_label) in self._rule_widgets.items():
                if name not in self._duck_rules:
                    rule_scale.set_value(percent)
                    rule_label.set_label(self._volume_text(percent))
            self._loading = False
        self._changed()

    def _on_rule_changed(
        self, scale: Gtk.Scale, name: str, value_label: Gtk.Label
    ) -> None:
        percent = scale.get_value()
        value_label.set_label(self._volume_text(percent))
        if not self._loading:
            self._duck_rules[name] = round(percent / 100.0, 2)
            self._changed()

    def _changed(self, *_args: object) -> None:
        if not self._loading:
            self._on_dirty()

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
        while child := self.apps_holder.get_first_child():
            self.apps_holder.remove(child)
        capturing = {
            app.name for app in self._detected_audio_apps.values() if app.captures
        }
        names = sorted(capturing | set(self._muted_apps), key=str.casefold)
        listbox = Gtk.ListBox(selection_mode=Gtk.SelectionMode.NONE)
        listbox.add_css_class("boxed-list")
        if not names:
            row = Adw.ActionRow(
                title="Nie wykryto aplikacji nagrywających",
                subtitle="Dołącz do rozmowy (np. na Discordzie) i odśwież listę.",
            )
            row.add_css_class("inactive")
            listbox.append(row)
        for name in names:
            detected = name in capturing
            row = Adw.SwitchRow(
                title=DISPLAY_NAMES.get(name, name),
                subtitle="nagrywa teraz" if detected else "zapamiętana · niedziałająca",
            )
            if not detected:
                row.add_css_class("inactive")
            row.set_active(
                name.casefold() in {item.casefold() for item in self._muted_apps}
            )
            row.connect(
                "notify::active",
                lambda widget, _p, value=name: self._toggle_mute_app(
                    value, widget.get_active()
                ),
            )
            listbox.append(row)
        self.apps_holder.append(listbox)

    def _render_duck_apps(self) -> None:
        for row in self._duck_app_rows:
            self.ducking_rows.remove(row)
        self._duck_app_rows.clear()
        self._rule_widgets.clear()

        names = sorted(
            set(self._detected_audio_apps) | set(self._duck_rules), key=str.casefold
        )
        if not names:
            row = Adw.ActionRow(
                title="Brak aktywnych aplikacji audio",
                subtitle="Uruchom odtwarzanie i odśwież listę.",
            )
            row.add_css_class("inactive")
            self.ducking_rows.append(row)
            self._duck_app_rows.append(row)
            return

        default_percent = self.default_duck_scale.get_value()
        for name in names:
            detected = self._detected_audio_apps.get(name)
            active = detected is not None
            if detected is not None and detected.playing:
                state = "gra teraz"
            elif detected is not None:
                state = "połączona"
            else:
                state = "zapamiętana · niedziałająca"
            row = Adw.ActionRow(
                title=DISPLAY_NAMES.get(name, name),
                subtitle=state,
            )
            row.add_css_class("audio-app-row")
            if not active:
                row.add_css_class("inactive")
            scale = self._volume_scale()
            percent = self._duck_rules.get(name, default_percent / 100.0) * 100.0
            scale.set_value(percent)
            value = self._volume_label()
            value.set_label(self._volume_text(percent))
            scale.connect("value-changed", self._on_rule_changed, name, value)
            row.add_suffix(scale)
            row.add_suffix(value)
            if not active and name in self._duck_rules:
                remove = Gtk.Button(icon_name="user-trash-symbolic")
                remove.add_css_class("icon-button")
                remove.set_tooltip_text(f"Usuń regułę dla {name}")
                remove.connect(
                    "clicked", lambda _button, current=name: self._remove_duck_rule(current)
                )
                row.add_suffix(remove)
            self.ducking_rows.append(row)
            self._duck_app_rows.append(row)
            self._rule_widgets[name] = (scale, value)
        self._set_duck_controls_sensitive()

    def _remove_duck_rule(self, name: str) -> None:
        self._duck_rules.pop(name, None)
        self._render_duck_apps()
        self._changed()
