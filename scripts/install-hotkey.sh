#!/usr/bin/env bash
# Registers the dictation hotkey with whatever desktop is running.
#
# GNOME     — gsettings custom keybinding (the original path)
# KDE       — a .desktop entry + kglobalshortcutsrc, reloaded over D-Bus
# Hyprland  — a `bind` line appended to hyprland.conf + hyprctl reload
# Sway      — a `bindsym` line appended to the sway config + swaymsg reload
#
# The compositor is detected from XDG_CURRENT_DESKTOP / the session; override
# with VOICEFLOW_DESKTOP=gnome|kde|hyprland|sway when the guess is wrong.
set -euo pipefail

VOICEFLOW_BIN="${HOME}/.local/bin/voiceflow"
# Super+D and Super+V are taken on GNOME; Super+G is free on every desktop
# we looked at. Override with VOICEFLOW_BINDING (GNOME accelerator syntax).
BINDING="${VOICEFLOW_BINDING:-<Super>g}"

usage() {
    echo "Użycie: $0 [--remove]"
    echo "Skrót zmienisz zmienną środowiskową, np. VOICEFLOW_BINDING='<Control><Alt>space' $0"
    echo "Pulpit wymusisz przez VOICEFLOW_DESKTOP=gnome|kde|hyprland|sway"
}

mode="install"
if [[ $# -gt 1 ]]; then usage >&2; exit 2; fi
if [[ $# -eq 1 ]]; then
    [[ "$1" == "--remove" ]] || { usage >&2; exit 2; }
    mode="remove"
fi

detect_desktop() {
    if [[ -n "${VOICEFLOW_DESKTOP:-}" ]]; then
        echo "$VOICEFLOW_DESKTOP"; return
    fi
    local d="${XDG_CURRENT_DESKTOP:-}${DESKTOP_SESSION:-}"
    shopt -s nocasematch
    case "$d" in
        *gnome*)    echo gnome ;;
        *kde*)      echo kde ;;
        *hyprland*) echo hyprland ;;
        *sway*)     echo sway ;;
        *)
            if [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then echo hyprland
            elif [[ -n "${SWAYSOCK:-}" ]]; then echo sway
            else echo unknown; fi ;;
    esac
    shopt -u nocasematch
}

# ---------------------------------------------------------------- GNOME ----
gnome_hotkey() {
    local SCHEMA="org.gnome.settings-daemon.plugins.media-keys"
    local KEY="custom-keybindings"
    local KEY_PATH="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/voiceflow/"
    local CUSTOM_SCHEMA="org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:${KEY_PATH}"
    local current updated
    current="$(gsettings get "$SCHEMA" "$KEY")"
    current="${current#@as }"

    if [[ "$mode" == "remove" ]]; then
        if [[ "$current" == *"'$KEY_PATH'"* ]]; then
            updated="$(sed \
                -e "s|'${KEY_PATH}', ||" \
                -e "s|, '${KEY_PATH}'||" \
                -e "s|\['${KEY_PATH}'\]|[]|" <<<"$current")"
            gsettings set "$SCHEMA" "$KEY" "$updated"
        fi
        gsettings reset "$CUSTOM_SCHEMA" name
        gsettings reset "$CUSTOM_SCHEMA" command
        gsettings reset "$CUSTOM_SCHEMA" binding
        echo "Usunięto skrót voiceflow (GNOME)."
        return
    fi

    if [[ "$current" != *"'$KEY_PATH'"* ]]; then
        if [[ "$current" == "[]" ]]; then
            updated="['$KEY_PATH']"
        else
            updated="${current%]}, '$KEY_PATH']"
        fi
        gsettings set "$SCHEMA" "$KEY" "$updated"
    fi
    gsettings set "$CUSTOM_SCHEMA" name "voiceflow — dyktowanie"
    gsettings set "$CUSTOM_SCHEMA" command "$VOICEFLOW_BIN toggle"
    gsettings set "$CUSTOM_SCHEMA" binding "$BINDING"
    echo "GNOME: skrót $BINDING uruchamia: $VOICEFLOW_BIN toggle"
}

# ------------------------------------------------------------------ KDE ----
# KDE keeps global shortcuts in kglobalshortcutsrc keyed by a .desktop entry.
kde_binding() {
    # GNOME accelerator -> KDE syntax: <Super>g -> Meta+G
    local b="$BINDING"
    b="${b//<Super>/Meta+}"; b="${b//<Control>/Ctrl+}"; b="${b//<Ctrl>/Ctrl+}"
    b="${b//<Alt>/Alt+}"; b="${b//<Shift>/Shift+}"
    # capitalise a trailing single letter (Meta+g -> Meta+G)
    if [[ "${b: -2:1}" == "+" ]]; then
        b="${b:0:-1}$(tr '[:lower:]' '[:upper:]' <<<"${b: -1}")"
    fi
    echo "$b"
}

kde_hotkey() {
    local APPS="$HOME/.local/share/applications"
    local DESKTOP="$APPS/voiceflow-toggle.desktop"
    local KWRITE QDBUS
    KWRITE="$(command -v kwriteconfig6 || command -v kwriteconfig5 || true)"
    QDBUS="$(command -v qdbus6 || command -v qdbus-qt6 || command -v qdbus || true)"

    if [[ "$mode" == "remove" ]]; then
        rm -f "$DESKTOP"
        [[ -n "$KWRITE" ]] && "$KWRITE" --file kglobalshortcutsrc \
            --group services --group voiceflow-toggle.desktop --key _launch --delete || true
        echo "Usunięto skrót voiceflow (KDE)."
        return
    fi

    mkdir -p "$APPS"
    cat > "$DESKTOP" <<EOF
[Desktop Entry]
Type=Application
Name=voiceflow — dyktowanie
Exec=$VOICEFLOW_BIN toggle
NoDisplay=true
StartupNotify=false
EOF

    local kb; kb="$(kde_binding)"
    if [[ -n "$KWRITE" ]]; then
        "$KWRITE" --file kglobalshortcutsrc \
            --group services --group voiceflow-toggle.desktop --key _launch "$kb"
        if [[ -n "$QDBUS" ]]; then
            "$QDBUS" org.kde.kglobalaccel /kglobalaccel org.kde.KGlobalAccel.reloadConfig \
                >/dev/null 2>&1 || true
        fi
        echo "KDE: skrót $kb uruchamia: $VOICEFLOW_BIN toggle"
        echo "  (jeśli nie działa od razu: Ustawienia systemowe → Skróty → sprawdź wpis „voiceflow”)"
    else
        echo "KDE: nie znalazłem kwriteconfig6/5 — dodaj skrót ręcznie:"
        echo "  Ustawienia systemowe → Skróty → Dodaj polecenie: $VOICEFLOW_BIN toggle → przypisz $kb"
    fi
}

# ----------------------------------------------------------- wlroots (2) ----
wlr_binding() {
    # <Super>g -> "SUPER, G" (Hyprland) / "Mod4+g" (Sway)
    local style="$1" b="$BINDING" mods=() key
    while [[ "$b" == \<* ]]; do
        mods+=("${b%%>*}"); mods[-1]="${mods[-1]#<}"
        b="${b#*>}"
    done
    key="$b"
    if [[ "$style" == hyprland ]]; then
        local out=""
        for m in "${mods[@]}"; do
            case "${m,,}" in
                super) out+="SUPER " ;;
                control|ctrl) out+="CTRL " ;;
                alt) out+="ALT " ;;
                shift) out+="SHIFT " ;;
            esac
        done
        echo "${out% }, ${key^^}"
    else
        local out=""
        for m in "${mods[@]}"; do
            case "${m,,}" in
                super) out+="Mod4+" ;;
                control|ctrl) out+="Ctrl+" ;;
                alt) out+="Mod1+" ;;
                shift) out+="Shift+" ;;
            esac
        done
        echo "${out}${key}"
    fi
}

MARK="# voiceflow hotkey (managed by install-hotkey.sh)"

append_managed_line() { # $1=config file, $2=line
    mkdir -p "$(dirname "$1")"
    touch "$1"
    sed -i "\|$MARK|d" "$1"
    printf '%s %s\n' "$2" "$MARK" >> "$1"
}

remove_managed_line() {
    [[ -f "$1" ]] && sed -i "\|$MARK|d" "$1" || true
}

hyprland_hotkey() {
    local CONF="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/hyprland.conf"
    if [[ "$mode" == "remove" ]]; then
        remove_managed_line "$CONF"
        command -v hyprctl >/dev/null && hyprctl reload >/dev/null 2>&1 || true
        echo "Usunięto skrót voiceflow (Hyprland)."
        return
    fi
    local kb; kb="$(wlr_binding hyprland)"
    append_managed_line "$CONF" "bind = $kb, exec, $VOICEFLOW_BIN toggle"
    command -v hyprctl >/dev/null && hyprctl reload >/dev/null 2>&1 || true
    echo "Hyprland: dopisano do $CONF: bind = $kb, exec, voiceflow toggle"
}

sway_hotkey() {
    local CONF="${XDG_CONFIG_HOME:-$HOME/.config}/sway/config"
    if [[ "$mode" == "remove" ]]; then
        remove_managed_line "$CONF"
        command -v swaymsg >/dev/null && swaymsg reload >/dev/null 2>&1 || true
        echo "Usunięto skrót voiceflow (Sway)."
        return
    fi
    local kb; kb="$(wlr_binding sway)"
    append_managed_line "$CONF" "bindsym $kb exec $VOICEFLOW_BIN toggle"
    command -v swaymsg >/dev/null && swaymsg reload >/dev/null 2>&1 || true
    echo "Sway: dopisano do $CONF: bindsym $kb exec voiceflow toggle"
}

# -------------------------------------------------------------------------
desktop="$(detect_desktop)"
case "$desktop" in
    gnome)    gnome_hotkey ;;
    kde)      kde_hotkey ;;
    hyprland) hyprland_hotkey ;;
    sway)     sway_hotkey ;;
    *)
        echo "Nie rozpoznałem pulpitu (XDG_CURRENT_DESKTOP='${XDG_CURRENT_DESKTOP:-}')." >&2
        echo "Dodaj skrót ręcznie: dowolny klawisz → polecenie: $VOICEFLOW_BIN toggle" >&2
        echo "Albo wymuś: VOICEFLOW_DESKTOP=gnome|kde|hyprland|sway $0" >&2
        exit 1
        ;;
esac
