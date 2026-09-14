#!/bin/bash
# Publikacja iOS do TestFlight / App Store: archiwum, eksport (App Store
# Connect), upload. Certyfikat „Apple Distribution” i profile prowizjonowania
# Xcode tworzy/odświeża sam z klucza API (`-allowProvisioningUpdates`).
#
# Użycie: tools/release-ios.sh [--no-upload]
#
# Wymaga: rekordu aplikacji w App Store Connect dla
# io.github.avejapl.voiceflow.ios (zakłada się ręcznie w ASC — API tego nie
# umie), klucza API w ~/.appstoreconnect, podbitego CFBundleVersion w
# ios/project.yml przy każdym uploadzie.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)

UPLOAD=1
[[ "${1:-}" == "--no-upload" ]] && UPLOAD=0

ASC_KEY_ID=${ASC_KEY_ID:-YMU9MZDABZ}
ASC_KEY="$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"
ASC_ISSUER=$(cat "$HOME/.appstoreconnect/issuer_id")
[[ -f "$ASC_KEY" ]] || { echo "[release-ios] brak klucza ASC: $ASC_KEY" >&2; exit 1; }

VERSION=$(grep 'MARKETING_VERSION:' ios/project.yml | head -1 | sed 's/.*"\(.*\)".*/\1/')
BUILD=$(grep 'CURRENT_PROJECT_VERSION:' ios/project.yml | head -1 | sed 's/.*"\(.*\)".*/\1/')
OUT="$ROOT/ios/build/release-${VERSION}-${BUILD}"
ARCHIVE="$OUT/VoiceFlow.xcarchive"
rm -rf "$OUT" && mkdir -p "$OUT"

echo "[release-ios] archiwum ${VERSION} (${BUILD})"
(cd ios && xcodegen generate >/dev/null)
xcodebuild -project ios/VoiceFlowIOS.xcodeproj -scheme VoiceFlowApp -configuration Release \
    -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$ASC_KEY" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER" \
    archive 2>&1 | grep -E "error:|ARCHIVE" | tail -3
[[ -d "$ARCHIVE" ]] || { echo "[release-ios] brak archiwum" >&2; exit 1; }

cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>export</string>
  <!-- Ręczne podpisanie profilami App Store założonymi przez API
       (tools/asc-profiles są w ~/Library/MobileDevice/Provisioning Profiles).
       Klucz API nie ma uprawnień do „cloud signing”, więc automatyczny
       tryb eksportu kończy się „Cloud signing permission error”. -->
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Apple Distribution</string>
  <key>teamID</key><string>H7DS3ZG67S</string>
  <key>provisioningProfiles</key><dict>
    <key>io.github.avejapl.voiceflow.ios</key><string>io.github.avejapl.voiceflow.ios AppStore</string>
    <key>io.github.avejapl.voiceflow.ios.keyboard</key><string>io.github.avejapl.voiceflow.ios.keyboard AppStore</string>
  </dict>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
PLIST

echo "[release-ios] eksport .ipa"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUT/export" \
    -exportOptionsPlist "$OUT/ExportOptions.plist" \
    2>&1 | grep -E "error:|EXPORT" | tail -3
IPA=$(ls "$OUT"/export/*.ipa | head -1)
[[ -f "$IPA" ]] || { echo "[release-ios] brak .ipa" >&2; exit 1; }
ls -la "$IPA"

if [[ $UPLOAD -eq 0 ]]; then
    echo "[release-ios] --no-upload: gotowe w $OUT"
    exit 0
fi

echo "[release-ios] upload do App Store Connect"
xcrun altool --upload-app -f "$IPA" -t ios --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER" 2>&1 | tail -5
echo "[release-ios] gotowe — build pojawi się w TestFlight po przetworzeniu (kilka–kilkanaście minut)"
