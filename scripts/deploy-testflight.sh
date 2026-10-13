#!/usr/bin/env bash
# Archive, sign in the cloud and upload to App Store Connect (TestFlight), in one run.
#
# The build number is the commit count, so this runs once per commit from a clean
# main: Apple refuses a second upload with the same number, and a number that does
# not match the repository is a lie in the report. It exits non-zero unless the
# export log says "Upload succeeded".
#
# Needs ship.env (committed) and ~/.config/testflight-deploy/config (KEY_ID,
# ISSUER_ID, TEAM_ID, P8_PATH; never printed, never committed).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
# shellcheck disable=SC1091
source ship.env
CONFIG="$HOME/.config/testflight-deploy/config"
[[ -f $CONFIG ]] || { echo "no $CONFIG; see docs/testflight.md"; exit 1; }
# shellcheck disable=SC1090
source "$CONFIG"
[[ -n ${ASC_APP_ID:-} ]] || echo "note: ASC_APP_ID is empty in ship.env; the upload works, the status check needs it"

if [[ -n $(git status --porcelain) ]]; then
  echo "the working tree is not clean; the build number would not match the repository. Commit first."
  exit 1
fi

BUILD_NUM=$(git rev-list --count HEAD)
echo "▸ build $BUILD_NUM of $SCHEME"
rm -rf build && mkdir -p build
sed "s/TEAM_ID_PLACEHOLDER/$TEAM_ID/" assets/ExportOptions.plist > build/ExportOptions.plist

xcodebuild archive \
  -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath build/app.xcarchive \
  -allowProvisioningUpdates -quiet \
  CURRENT_PROJECT_VERSION="$BUILD_NUM"

xcodebuild -exportArchive \
  -archivePath build/app.xcarchive \
  -exportOptionsPlist build/ExportOptions.plist \
  -exportPath build/export \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$P8_PATH" \
  -authenticationKeyID "$KEY_ID" \
  -authenticationKeyIssuerID "$ISSUER_ID" 2>&1 | tee build/export.log | grep -E "Upload succeeded|error:|EXPORT (SUCCEEDED|FAILED)" || true

# The grep above swallows xcodebuild's exit status, so the log decides.
if ! grep -q "Upload succeeded" build/export.log; then
  echo "▸ build $BUILD_NUM was NOT uploaded; the full log is $(pwd)/build/export.log"
  exit 1
fi
echo
echo "▸ build $BUILD_NUM uploaded; App Store Connect lists it after a few minutes, processing takes 5-15"
echo "▸ then: make testflight-status"
