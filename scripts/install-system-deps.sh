#!/usr/bin/env bash
# System dependencies for voiceflow (Ubuntu/Debian). Run: sudo bash scripts/install-system-deps.sh
#
# Installs:
#   ydotool      - key injection through /dev/uinput (the only path that works
#                  on GNOME Wayland, which implements no virtual-keyboard protocol)
#   wl-clipboard - wl-copy/wl-paste, used for pasting the transcribed text
#   python3-gi-cairo - Cairo context converter used by GTK application charts
#   gir1.2-ayatanaappindicator3-0.1 - top-bar icon for the dictation-stats
#                  tray widget (scripts/voiceflow-tray.py)
#
# Configures:
#   - a udev rule granting the active seat access to /dev/uinput via uaccess ACL.
#     Deliberately NOT the common "add yourself to the input group" advice: that
#     group grants read access to EVERY input device (i.e. a keylogger surface),
#     while uaccess covers this one node for the logged-in session only.
#   - the uinput module loaded at boot.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Run with sudo: sudo bash $0" >&2
    exit 1
fi

echo "==> Installing packages (apt update may take a minute, quietly)..."
apt-get update -qq
apt-get install -y ydotool wl-clipboard python3-gi-cairo gir1.2-ayatanaappindicator3-0.1

echo "==> udev rule for /dev/uinput (uaccess, not the input group)"
cat > /etc/udev/rules.d/60-voiceflow-uinput.rules <<'EOF'
KERNEL=="uinput", SUBSYSTEM=="misc", TAG+="uaccess", OPTIONS+="static_node=uinput"
EOF

echo "==> Loading uinput at boot"
echo uinput > /etc/modules-load.d/voiceflow-uinput.conf
modprobe uinput || true

echo "==> Reloading udev rules"
udevadm control --reload-rules
udevadm trigger --subsystem-match=misc --sysname-match=uinput

echo
echo "Done. Verify the ACL below contains your user (log out/in if it does not):"
getfacl -p /dev/uinput 2>/dev/null || ls -l /dev/uinput
