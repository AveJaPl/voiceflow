#!/usr/bin/env bash
# voiceflow installer — no git required.
#
#   curl -fsSL https://raw.githubusercontent.com/AveJaPl/voiceflow/main/install.sh | bash
#
# What it does, in order:
#   1. downloads the latest release into ~/.local/share/voiceflow
#   2. installs uv (if missing) and syncs the Python environment
#   3. installs the `voiceflow` command into ~/.local/bin
#   4. sets up the user systemd service and the GNOME hotkey (Super+G)
#   5. if system dependencies (ydotool, wl-clipboard, udev rule) are missing,
#      runs the bundled script for them — this is the only step needing sudo
#
# Re-running updates an existing installation in place.
set -euo pipefail

REPO="AveJaPl/voiceflow"
DEST="${VOICEFLOW_HOME:-$HOME/.local/share/voiceflow}"
BIN="$HOME/.local/bin"

say()  { printf '\033[1m==> %s\033[0m\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

command -v curl >/dev/null || fail "curl is required"
command -v tar  >/dev/null || fail "tar is required"

# WSL is Windows wearing a Linux costume: no real microphone routing and no way
# to paste into Windows applications from here. Point the user at the right build.
if grep -qiE "microsoft|wsl" /proc/version 2>/dev/null; then
    echo ""
    echo "  Wykryto WSL — jesteś na Windowsie."
    echo "  Ta wersja (Linux) nie zadziała w WSL: brak dostępu do mikrofonu"
    echo "  i brak możliwości wklejania do okien Windows."
    echo ""
    echo "  Użyj instalatora Windows: pobierz voiceflow-install.bat z"
    echo "  https://github.com/AveJaPl/voiceflow/releases/latest i kliknij dwukrotnie."
    exit 1
fi

say "Downloading voiceflow"
TARBALL_URL=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
    | grep -o '"tarball_url": *"[^"]*"' | cut -d'"' -f4 || true)
# No release yet (or API rate-limited): fall back to the main branch.
[ -n "$TARBALL_URL" ] || TARBALL_URL="https://api.github.com/repos/$REPO/tarball/main"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
curl -fsSL "$TARBALL_URL" -o "$TMP/voiceflow.tar.gz"
mkdir -p "$DEST"
tar -xzf "$TMP/voiceflow.tar.gz" --strip-components=1 -C "$DEST"

say "Setting up Python environment"
if ! command -v uv >/dev/null && [ ! -x "$HOME/.local/bin/uv" ]; then
    say "Installing uv (Python manager, into your home directory)"
    curl -LsSf https://astral.sh/uv/install.sh | sh
fi
UV=$(command -v uv || echo "$HOME/.local/bin/uv")
(cd "$DEST" && "$UV" sync -q)

say "Installing the voiceflow command"
mkdir -p "$BIN"
printf '#!/usr/bin/env bash\nexec "%s/.venv/bin/voiceflow" "$@"\n' "$DEST" > "$BIN/voiceflow"
chmod +x "$BIN/voiceflow"
case ":$PATH:" in
    *":$BIN:"*) ;;
    *) echo "note: add $BIN to your PATH" ;;
esac

if ! command -v ydotool >/dev/null || [ ! -e /dev/uinput ]; then
    say "System dependencies missing — this one step needs sudo"
    echo "  (hasło wpisuje się niewidocznie — to normalne; potem apt może"
    echo "   pracować ~minutę bez żadnego wyjścia)"
    sudo bash "$DEST/scripts/install-system-deps.sh"
fi

say "Setting up services and hotkey"
mkdir -p "$HOME/.config/systemd/user"
cp "$DEST/systemd/voiceflow.service" "$HOME/.config/systemd/user/"
systemctl --user daemon-reload
systemctl --user enable --now ydotool.service 2>/dev/null || true
systemctl --user enable voiceflow.service
systemctl --user restart voiceflow.service
bash "$DEST/scripts/install-hotkey.sh"

say "Done"
echo
echo "  First start downloads the speech model (~1.6 GB); watch with:"
echo "      journalctl --user -u voiceflow -f"
echo "  Then press Super+G, speak, press Super+G again."
echo "  Health check:   voiceflow status"
echo "  Configuration:  ~/.config/voiceflow/config.yaml"
