#!/usr/bin/env bash
# Mac App Store submission pipeline for Verbinal.
#
# Prerequisites (done once):
#   1. Developer account enrolled, team A4ABW5VD88.
#   2. App ID created at developer.apple.com for com.codebg.Verbinal,
#      with the "Mac App Store" capability enabled.
#   3. A provisioning profile named "Verbinal MAS" created for that App ID
#      and downloaded into ~/Library/MobileDevice/Provisioning Profiles/.
#   4. Two signing certs imported into the login keychain:
#        - "3rd Party Mac Developer Application" (signs the .app)
#        - "3rd Party Mac Developer Installer"   (signs the .pkg)
#   5. A valid App Store Connect listing for the bundle ID, with at minimum:
#        - App name, subtitle, description
#        - Category (Education)
#        - Screenshots at 1280×800 or 2880×1800
#        - Privacy Policy URL
#        - Support URL
#        - Privacy "Nutrition Label" answered in App Privacy
#   6. An App Store Connect API key, or an app-specific password for your Apple ID.
#
# Environment variables consumed by this script:
#   APPLE_ID_EMAIL     — Apple ID used for submission (if using --apple-id auth)
#   APP_PASSWORD       — app-specific password for that Apple ID (keychain reference
#                        via @keychain:ITEM works too, see `xcrun notarytool store-credentials`)
#   APP_STORE_KEY_ID   — App Store Connect API key id (preferred over apple-id)
#   APP_STORE_ISSUER   — App Store Connect issuer uuid
#   APP_STORE_KEY_PATH — path to the .p8 private key file
#
# Usage:
#   scripts/mas-submit.sh                 # build + validate only (no upload)
#   UPLOAD=1 scripts/mas-submit.sh        # build + validate + upload to App Store Connect

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

BUILD_DIR="$REPO_ROOT/build"
ARCHIVE_PATH="$BUILD_DIR/Verbinal.xcarchive"
EXPORT_PATH="$BUILD_DIR/mas"
PKG_PATH=""  # resolved after export

log() { printf '[mas-submit] %s\n' "$*"; }

# ------------------------------------------------------------------
# 1. Regenerate project (picks up any project.yml changes).
# ------------------------------------------------------------------
log "regenerating Xcode project"
xcodegen generate >/dev/null

# ------------------------------------------------------------------
# 2. Archive.
# ------------------------------------------------------------------
log "archiving (Release config, bundles Python automatically)"
rm -rf "$ARCHIVE_PATH"
xcodebuild \
    -project Verbinal.xcodeproj \
    -scheme Verbinal \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE_PATH" \
    archive \
    | xcbeautify --renderer terminal 2>/dev/null || true

if [[ ! -d "$ARCHIVE_PATH" ]]; then
    echo "ERROR: archive not produced at $ARCHIVE_PATH" >&2
    exit 2
fi

# ------------------------------------------------------------------
# 3. Export signed .pkg for Mac App Store.
# ------------------------------------------------------------------
log "exporting signed .pkg"
rm -rf "$EXPORT_PATH"
xcodebuild \
    -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$REPO_ROOT/scripts/mas-export-options.plist"

PKG_PATH="$(find "$EXPORT_PATH" -name '*.pkg' -type f | head -n 1)"
if [[ -z "$PKG_PATH" ]]; then
    echo "ERROR: no .pkg produced in $EXPORT_PATH" >&2
    exit 3
fi
log "signed package: $PKG_PATH"

# ------------------------------------------------------------------
# 4. Validate (always) and optionally upload.
# ------------------------------------------------------------------
validate_args=(--type macos --file "$PKG_PATH")

if [[ -n "${APP_STORE_KEY_ID:-}" ]]; then
    validate_args+=(--apiKey "$APP_STORE_KEY_ID" --apiIssuer "$APP_STORE_ISSUER")
elif [[ -n "${APPLE_ID_EMAIL:-}" ]]; then
    validate_args+=(--username "$APPLE_ID_EMAIL" --password "${APP_PASSWORD:-}")
else
    echo "ERROR: set APP_STORE_KEY_ID+APP_STORE_ISSUER+APP_STORE_KEY_PATH or APPLE_ID_EMAIL+APP_PASSWORD" >&2
    exit 4
fi

log "validating with App Store Connect"
xcrun altool --validate-app "${validate_args[@]}"
log "validation passed"

if [[ "${UPLOAD:-0}" == "1" ]]; then
    log "uploading to App Store Connect"
    xcrun altool --upload-app "${validate_args[@]}"
    log "upload complete — check App Store Connect for build processing status"
else
    log "set UPLOAD=1 to push the build (skipped)"
fi
