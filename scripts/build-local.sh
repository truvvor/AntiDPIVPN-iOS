#!/usr/bin/env bash
#
# Local build + TestFlight upload for AntiDPIVPN, mirrors .github/workflows/build.yml.
# Run on any Mac with Xcode 26.4+, xcodegen, and the ASC API .p8 key installed.
#
# Usage:
#     ./scripts/build-local.sh
#
# Prereqs on the Mac:
#     1. Signing certs installed in login.keychain (Apple Development + Apple Distribution)
#     2. Xcode logged in to the Apple ID with team WJWU38ALPB
#     3. xcodegen: brew install xcodegen
#     4. ASC API key .p8 file at:
#          ~/.appstoreconnect/private_keys/AuthKey_4RA5988Z6S.p8
#        (or ~/Library/Keys/AuthKey_4RA5988Z6S.p8 — altool looks in both)
#     5. Optional: set KEYCHAIN_PASSWORD env var if your login-keychain password
#        differs from your macOS user password. Defaults to prompting.
#
# What it does:
#     - unlocks login.keychain (needed for codesign)
#     - runs xcodegen (regenerates .xcodeproj from project.yml)
#     - xcodebuild archive → exportArchive → altool upload
#     - stages dSYMs into ./build/dsyms/ for later symbolication
#     - cleans up intermediate artifacts

set -euo pipefail

# --- config ---
readonly SCHEME="AntiDPIVPN"
readonly TEAM_ID="WJWU38ALPB"
readonly ASC_KEY_ID="4RA5988Z6S"
readonly ASC_ISSUER_ID="e51df9f1-5d4a-4eb9-83e1-a8d49966cdfc"
readonly WORK_DIR="${TMPDIR:-/tmp}/antidpivpn-build.$$"
readonly REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
readonly DSYM_OUT="${REPO_ROOT}/build/dsyms"

cd "$REPO_ROOT"

# --- keychain unlock ---
echo "==> Unlocking login keychain"
if [[ -z "${KEYCHAIN_PASSWORD:-}" ]]; then
    read -rsp "  Login keychain password: " KEYCHAIN_PASSWORD
    echo
fi
security list-keychains -d user -s \
    ~/Library/Keychains/login.keychain-db \
    /Library/Keychains/System.keychain
security unlock-keychain -p "$KEYCHAIN_PASSWORD" ~/Library/Keychains/login.keychain-db
security set-key-partition-list -S apple-tool:,apple:,codesign: \
    -s -k "$KEYCHAIN_PASSWORD" ~/Library/Keychains/login.keychain-db >/dev/null 2>&1
security set-keychain-settings -lut 21600 ~/Library/Keychains/login.keychain-db

echo "==> Signing identities available:"
security find-identity -v -p codesigning

# --- xcodegen ---
echo "==> Regenerating project"
if ! command -v xcodegen >/dev/null 2>&1; then
    echo "ERROR: xcodegen not found. Install: brew install xcodegen" >&2
    exit 1
fi
xcodegen generate --spec project.yml

# --- prepare work dir ---
mkdir -p "$WORK_DIR"
trap 'rm -rf "$WORK_DIR"' EXIT
readonly ARCHIVE_PATH="${WORK_DIR}/${SCHEME}.xcarchive"
readonly EXPORT_DIR="${WORK_DIR}/export"
readonly EXPORT_OPTS="${WORK_DIR}/ExportOptions.plist"

# --- archive ---
echo "==> Archiving (this takes 5-10 min)"
xcodebuild -scheme "$SCHEME" \
    -sdk iphoneos \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    archive \
    -allowProvisioningUpdates \
    CODE_SIGN_STYLE=Automatic \
    DEVELOPMENT_TEAM="$TEAM_ID"

# --- ExportOptions.plist ---
cat >"$EXPORT_OPTS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>app-store-connect</string>
  <key>uploadSymbols</key>
  <false/>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>teamID</key>
  <string>${TEAM_ID}</string>
</dict>
</plist>
PLIST

# --- export IPA ---
echo "==> Exporting IPA"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTS" \
    -allowProvisioningUpdates

# --- upload to TestFlight ---
echo "==> Uploading to App Store Connect / TestFlight"
xcrun altool --upload-app \
    -f "${EXPORT_DIR}/${SCHEME}.ipa" \
    -t ios \
    --apiKey "$ASC_KEY_ID" \
    --apiIssuer "$ASC_ISSUER_ID"

# --- stash dSYMs ---
mkdir -p "$DSYM_OUT"
if [[ -d "${ARCHIVE_PATH}/dSYMs" ]]; then
    cp -R "${ARCHIVE_PATH}/dSYMs" "$DSYM_OUT/"
    echo "==> dSYMs saved to $DSYM_OUT/dSYMs"
fi
if [[ -f "${ARCHIVE_PATH}/Products/Applications/${SCHEME}.app/${SCHEME}" ]]; then
    cp "${ARCHIVE_PATH}/Products/Applications/${SCHEME}.app/${SCHEME}" \
        "$DSYM_OUT/${SCHEME}.bin"
fi

echo
echo "==> Done."
echo "    IPA:     ${EXPORT_DIR}/${SCHEME}.ipa (will be removed on exit)"
echo "    dSYMs:   ${DSYM_OUT}/dSYMs"
echo "    Build should appear in App Store Connect within ~15 min."
