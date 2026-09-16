#!/bin/bash
# Publikacja wersji macOS: podpis Developer ID, notaryzacja, DMG dla pierwszej
# instalacji i ZIP dla kanału samo-aktualizacji (GitHub Releases, tag
# `mac-vX.Y.Z`, asset `VoiceFlow-mac.zip` — tego szuka `UpdateChecker`).
#
# Użycie: tools/release-mac.sh [--dry-run]
#   --dry-run  buduje, podpisuje, notaryzuje i składa artefakty, ale nie tworzy
#              release'u na GitHubie (artefakty zostają w $OUT).
#
# Wymagania na maszynie:
#   - third_party/whisper-macos zbudowane (tools/build-whisper-macos.sh),
#   - certyfikat „Developer ID Application” w Keychainie (zespół H7DS3ZG67S),
#   - klucz App Store Connect API w ~/.appstoreconnect (do notarytool),
#   - gh zalogowany z prawem do AveJaPl/voiceflow.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

TEAM_ID=H7DS3ZG67S
SIGN_IDENTITY="Developer ID Application"
ASC_KEY_ID=${ASC_KEY_ID:-YMU9MZDABZ}
ASC_KEY="$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"
ASC_ISSUER=$(cat "$HOME/.appstoreconnect/issuer_id")

VERSION=$(grep 'MARKETING_VERSION:' macos/project.yml | head -1 | sed 's/.*"\(.*\)".*/\1/')
TAG="mac-v${VERSION}"
OUT="$ROOT/macos/build/release-${VERSION}"
SOURCE_COMMIT=$(git rev-parse HEAD)
# GitHub otherwise tags the default branch, not the code we actually built.
if [[ $DRY_RUN -eq 0 ]] && [[ -n "$(git status --porcelain -- macos shared tools/release-mac.sh)" ]]; then
    echo "[release-mac] commit Apple sources before publishing" >&2
    exit 1
fi

if ! security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY"; then
    echo "[release-mac] brak certyfikatu „$SIGN_IDENTITY” w Keychainie." >&2
    echo "  Tworzy go WYŁĄCZNIE właściciel konta (Account Holder) na developer.apple.com →" >&2
    echo "  Certificates → + → Developer ID Application → CSR z ~/keystores/voiceflow-developer-id/devid.csr," >&2
    echo "  potem: security import developerID_application.cer -k ~/Library/Keychains/login.keychain-db" >&2
    echo "         security import ~/keystores/voiceflow-developer-id/devid.key -k ~/Library/Keychains/login.keychain-db" >&2
    exit 1
fi
[[ -f "$ASC_KEY" ]] || { echo "[release-mac] brak klucza ASC: $ASC_KEY" >&2; exit 1; }
[[ -f third_party/whisper-macos/lib/libwhisper.a ]] || tools/build-whisper-macos.sh

if [[ $DRY_RUN -eq 0 ]] && gh release view "$TAG" --repo AveJaPl/voiceflow >/dev/null 2>&1; then
    echo "Release $TAG już istnieje — podbij MARKETING_VERSION w macos/project.yml." >&2
    exit 1
fi

echo "[release-mac] buduję Release ${VERSION} (Developer ID, hardened runtime)"
rm -rf "$OUT" && mkdir -p "$OUT"
(cd macos && xcodegen generate >/dev/null)
xcodebuild -project macos/VoiceFlow.xcodeproj -scheme VoiceFlow -configuration Release \
    -derivedDataPath macos/build/DerivedData-release \
    -jobs "${VOICEFLOW_BUILD_JOBS:-2}" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    OTHER_CODE_SIGN_FLAGS="--timestamp" \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    build 2>&1 | grep -E "error:|BUILD" | tail -3
# `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO`: zwykły `xcodebuild build` (nie
# archive) dokłada `com.apple.security.get-task-allow`, a notaryzacja to odrzuca
# („The executable requests the com.apple.security.get-task-allow entitlement”,
# 2026-09-14).

APP="$ROOT/macos/build/DerivedData-release/Build/Products/Release/VoiceFlow.app"
[[ -d "$APP" ]] || { echo "[release-mac] brak $APP" >&2; exit 1; }
APP_VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
[[ "$APP_VERSION" == "$VERSION" ]] || { echo "[release-mac] version mismatch: bundle=$APP_VERSION tag=$VERSION" >&2; exit 1; }

echo "[release-mac] sprawdzam, że apka nie zależy od Homebrew"
if otool -L "$APP/Contents/MacOS/VoiceFlow" | grep -q /opt/homebrew; then
    otool -L "$APP/Contents/MacOS/VoiceFlow" | grep /opt/homebrew >&2
    echo "[release-mac] STOP: plik wykonywalny linkuje biblioteki z Homebrew" >&2
    exit 1
fi
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -2

echo "[release-mac] notaryzuję apkę"
NOTARY_ZIP="$OUT/VoiceFlow-notary.zip"
ditto -ck --keepParent "$APP" "$NOTARY_ZIP"
xcrun notarytool submit "$NOTARY_ZIP" --key "$ASC_KEY" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER" --wait 2>&1 | tail -3
xcrun stapler staple "$APP" | tail -1
rm -f "$NOTARY_ZIP"

echo "[release-mac] składam artefakty"
ZIP="$OUT/VoiceFlow-mac.zip"
ditto -ck --keepParent "$APP" "$ZIP"

DMG="$OUT/VoiceFlow-mac.dmg"
STAGE="$OUT/dmg-stage"
rm -rf "$STAGE" && mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "VoiceFlow" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --key "$ASC_KEY" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER" --wait 2>&1 | tail -3
xcrun stapler staple "$DMG" | tail -1
spctl -a -t open --context context:primary-signature -v "$DMG" 2>&1 | tail -1

ls -la "$OUT"
if [[ $DRY_RUN -eq 1 ]]; then
    echo "[release-mac] dry-run: artefakty w $OUT, release NIE utworzony"
    exit 0
fi

echo "[release-mac] publikuję ${TAG}"
gh release create "$TAG" "$ZIP" "$DMG" \
    --repo AveJaPl/voiceflow \
    --target "$SOURCE_COMMIT" \
    --title "VoiceFlow mac ${VERSION}" \
    --notes "macOS ${VERSION}. DMG do pierwszej instalacji (podpisany Developer ID, notaryzowany); ZIP jest kanałem samo-aktualizacji."
echo "[release-mac] gotowe: ${TAG}"
