#!/bin/bash
# Publikacja wersji macOS do kanału samo-aktualizacji (GitHub Releases).
#
# Użycie: tools/release-mac.sh
# Bierze wersję z macos/project.yml (MARKETING_VERSION), buduje Release,
# pakuje ditto -ck (zachowuje podpis) i tworzy release `mac-v<wersja>`
# z assetem VoiceFlow-mac.zip — dokładnie tym, czego szuka UpdateChecker.
set -euo pipefail
cd "$(dirname "$0")/../macos"

VERSION=$(grep 'MARKETING_VERSION:' project.yml | head -1 | sed 's/.*"\(.*\)".*/\1/')
TAG="mac-v${VERSION}"

if gh release view "$TAG" --repo AveJaPl/voiceflow >/dev/null 2>&1; then
    echo "Release $TAG już istnieje — podbij MARKETING_VERSION w project.yml." >&2
    exit 1
fi

echo "[release-mac] buduję Release ${VERSION}…"
xcodegen generate >/dev/null
xcodebuild -project VoiceFlow.xcodeproj -scheme VoiceFlow -configuration Release build 2>&1 \
    | grep -E "error:|BUILD" | tail -2

APP="$(xcodebuild -project VoiceFlow.xcodeproj -scheme VoiceFlow -configuration Release -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR/{print $3}')/VoiceFlow.app"
ZIP="/tmp/VoiceFlow-mac.zip"
rm -f "$ZIP"
ditto -ck --keepParent "$APP" "$ZIP"

echo "[release-mac] publikuję $TAG…"
gh release create "$TAG" "$ZIP" \
    --repo AveJaPl/voiceflow \
    --title "VoiceFlow mac ${VERSION}" \
    --notes "Automatyczna publikacja kanału samo-aktualizacji macOS."
echo "[release-mac] gotowe: $TAG"
