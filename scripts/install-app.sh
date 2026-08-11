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
# Bez tego `installed_version()` czyta pustkę i zwraca 0.0.0, przez co
# sprawdzanie wydań uznaje KAŻDE wydanie za nowsze i zapala przycisk
# aktualizacji na stałe.
install -m 0644 "${PROJECT_ROOT}/pyproject.toml" "${APP_INSTALL_ROOT}/pyproject.toml"

while IFS= read -r -d '' source_file; do
    relative_path="${source_file#"${PROJECT_ROOT}/app/voiceflow_app/"}"
    target_file="${APP_INSTALL_ROOT}/app/voiceflow_app/${relative_path}"
    install -d -m 0755 "$(dirname -- "${target_file}")"
    install -m 0644 "${source_file}" "${target_file}"
done < <(find "${PROJECT_ROOT}/app/voiceflow_app" -type f -name '*.py' -print0)

# Skąd pochodzi ta kopia. Bez tego okno nie ma jak sprawdzić, czy kod
# źródłowy zdążył się zmienić — a wtedy „czy mam bieżącą wersję?" znów
# byłoby pytaniem bez odpowiedzi.
printf '%s\n' "${PROJECT_ROOT}" > "${APP_INSTALL_ROOT}/.source"

# Znacznik czasu instalacji. Po nim wrapper poznaje, czy kod źródłowy zdążył
# się zmienić — porównanie dat plików jest tańsze i pewniejsze niż numer wersji,
# który przy pracy nad kodem stoi w miejscu.
touch -- "${APP_INSTALL_ROOT}/.installed"

# Wrapper dosynchrowuje kopię przy KAŻDYM uruchomieniu. Bez tego edycja kodu
# w repozytorium nie docierała do skrótu w menu i aplikacja po cichu chodziła
# na starej wersji — co kosztowało nas jedno szukanie nieistniejącej usterki.
temporary_wrapper="$(mktemp "${BIN_DIR}/.voiceflow-app.XXXXXX")"
trap 'rm -f -- "${temporary_wrapper}"' EXIT
cat > "${temporary_wrapper}" <<WRAPPER
#!/usr/bin/env bash
# Wygenerowane przez scripts/install-app.sh — nie edytuj ręcznie.
SOURCE_ROOT=$(printf '%q' "${PROJECT_ROOT}")
INSTALL_ROOT=$(printf '%q' "${APP_INSTALL_ROOT}")

# Katalog źródłowy może już nie istnieć (instalacja z paczki, przeniesione
# repozytorium). Wtedy po prostu uruchamiamy to, co jest — brak źródeł nie
# jest błędem.
if [[ "\${VOICEFLOW_APP_NO_SYNC:-}" != "1" && -x "\${SOURCE_ROOT}/scripts/install-app.sh" ]]; then
    if [[ -n "\$(find "\${SOURCE_ROOT}/app" "\${SOURCE_ROOT}/scripts/voiceflow-app.py" \\
                 -newer "\${INSTALL_ROOT}/.installed" -print -quit 2>/dev/null)" ]]; then
        echo "voiceflow: kod źródłowy jest nowszy, aktualizuję aplikację…" >&2
        # Nieudana aktualizacja nie może odebrać działającej aplikacji.
        "\${SOURCE_ROOT}/scripts/install-app.sh" >/dev/null || \\
            echo "voiceflow: aktualizacja się nie powiodła, uruchamiam poprzednią wersję" >&2
    fi
fi

exec /usr/bin/python3 "\${INSTALL_ROOT}/scripts/voiceflow-app.py" "\$@"
WRAPPER
chmod 0755 "${temporary_wrapper}"
mv -f -- "${temporary_wrapper}" "${WRAPPER_TARGET}"
trap - EXIT

refresh_desktop_database
echo "Zainstalowano aplikację voiceflow. Uruchom ją z menu aplikacji lub poleceniem: voiceflow-app"
echo "Kolejne zmiany w ${PROJECT_ROOT} dociągną się same przy następnym uruchomieniu."
