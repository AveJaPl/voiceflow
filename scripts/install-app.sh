#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
APPLICATION_ID="io.github.avejapl.voiceflow"

APPLICATIONS_DIR="${HOME}/.local/share/applications"
ICONS_DIR="${HOME}/.local/share/icons/hicolor/scalable/apps"
BIN_DIR="${HOME}/.local/bin"
LOCAL_LIB_DIR="${HOME}/.local/lib"
APP_INSTALL_ROOT="${LOCAL_LIB_DIR}/voiceflow-app"

DESKTOP_TARGET="${APPLICATIONS_DIR}/${APPLICATION_ID}.desktop"
ICON_TARGET="${ICONS_DIR}/${APPLICATION_ID}.svg"
WRAPPER_TARGET="${BIN_DIR}/voiceflow-app"

usage() {
    echo "Użycie: $0 [--remove]"
}

if [[ $# -gt 1 ]]; then
    usage >&2
    exit 2
fi

if [[ $# -eq 1 && "$1" != "--remove" ]]; then
    usage >&2
    exit 2
fi

refresh_desktop_database() {
    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database "${APPLICATIONS_DIR}" >/dev/null 2>&1 || true
    fi
}

if [[ ${1:-} == "--remove" ]]; then
    rm -f -- "${DESKTOP_TARGET}" "${ICON_TARGET}" "${WRAPPER_TARGET}"
    rm -rf -- "${APP_INSTALL_ROOT}"
    refresh_desktop_database
    echo "Usunięto aplikację voiceflow."
    exit 0
fi

install -d -m 0755 \
    "${APPLICATIONS_DIR}" \
    "${ICONS_DIR}" \
    "${BIN_DIR}" \
    "${APP_INSTALL_ROOT}/scripts" \
    "${APP_INSTALL_ROOT}/app/voiceflow_app/pages"
install -m 0644 "${PROJECT_ROOT}/app/${APPLICATION_ID}.desktop" "${DESKTOP_TARGET}"
install -m 0644 "${PROJECT_ROOT}/app/${APPLICATION_ID}.svg" "${ICON_TARGET}"
install -m 0644 \
    "${PROJECT_ROOT}/app/${APPLICATION_ID}.svg" \
    "${APP_INSTALL_ROOT}/app/${APPLICATION_ID}.svg"
install -m 0755 \
    "${PROJECT_ROOT}/scripts/voiceflow-app.py" \
    "${APP_INSTALL_ROOT}/scripts/voiceflow-app.py"

while IFS= read -r -d '' source_file; do
    relative_path="${source_file#"${PROJECT_ROOT}/app/voiceflow_app/"}"
    target_file="${APP_INSTALL_ROOT}/app/voiceflow_app/${relative_path}"
    install -d -m 0755 "$(dirname -- "${target_file}")"
    install -m 0644 "${source_file}" "${target_file}"
done < <(find "${PROJECT_ROOT}/app/voiceflow_app" -type f -name '*.py' -print0)

temporary_wrapper="$(mktemp "${BIN_DIR}/.voiceflow-app.XXXXXX")"
trap 'rm -f -- "${temporary_wrapper}"' EXIT
printf '#!/usr/bin/env bash\nexec /usr/bin/python3 %q "$@"\n' \
    "${APP_INSTALL_ROOT}/scripts/voiceflow-app.py" > "${temporary_wrapper}"
chmod 0755 "${temporary_wrapper}"
mv -f -- "${temporary_wrapper}" "${WRAPPER_TARGET}"
trap - EXIT

refresh_desktop_database
echo "Zainstalowano aplikację voiceflow. Uruchom ją z menu aplikacji lub poleceniem: voiceflow-app"
