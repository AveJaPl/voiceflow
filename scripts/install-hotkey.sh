#!/usr/bin/env bash
set -euo pipefail

SCHEMA="org.gnome.settings-daemon.plugins.media-keys"
KEY="custom-keybindings"
KEY_PATH="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/voiceflow/"
CUSTOM_SCHEMA="org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:${KEY_PATH}"
VOICEFLOW_BIN="${HOME}/.local/bin/voiceflow"
# Super+D i Super+V sa zajete przez GNOME ("pokaz pulpit" i zasobnik powiadomien).
# Super+G jest wolny; nadpisz zmienna VOICEFLOW_BINDING, zeby uzyc innego.
BINDING="${VOICEFLOW_BINDING:-<Super>g}"

usage() {
    echo "Użycie: $0 [--remove]"
    echo "Skrót zmienisz zmienną środowiskową, np. VOICEFLOW_BINDING='<Control><Alt>space' $0"
}

if [[ $# -gt 1 ]]; then
    usage >&2
    exit 2
fi

mode="install"
if [[ $# -eq 1 ]]; then
    if [[ "$1" != "--remove" ]]; then
        usage >&2
        exit 2
    fi
    mode="remove"
fi

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
    echo "Usunięto skrót voiceflow."
    exit 0
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
echo "Skrót $BINDING uruchamia: $VOICEFLOW_BIN toggle"

