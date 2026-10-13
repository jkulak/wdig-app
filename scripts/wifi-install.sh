#!/usr/bin/env bash
# Build a Debug build for the phone and install it over the network with devicectl.
#
# Ends by asking the phone which bundle version it now has, and prints that, not
# the number built. The phone has to be paired with Xcode ("Connect via network")
# and on this network; a locked phone takes the install but refuses the launch.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
# shellcheck disable=SC1091
source ship.env
CONFIG="$HOME/.config/testflight-deploy/config"
# shellcheck disable=SC1090
[[ -f $CONFIG ]] && source "$CONFIG"

# The phone: DEVICE_UDID from the shared config, else the only paired one.
json=$(mktemp)
xcrun devicectl list devices --json-output "$json" >/dev/null
UDID=$(python3 - "$json" "${DEVICE_UDID:-}" <<'PY'
import json, sys
devices = [d for d in json.load(open(sys.argv[1]))["result"]["devices"]
           if d["connectionProperties"].get("pairingState") == "paired"]
want = sys.argv[2]
if want:
    devices = [d for d in devices if d["identifier"] == want] or devices
print(devices[0]["identifier"] if devices else "")
PY
)
rm -f "$json"
[[ -n $UDID ]] || { echo "no paired iPhone found"; exit 1; }

BUILD_NUM=$(git rev-list --count HEAD)
echo "▸ building $SCHEME build $BUILD_NUM for the phone"
[[ -z $(git status --porcelain) ]] || echo "note: uncommitted changes go into this build, so build $BUILD_NUM does not describe it"
rm -rf build-phone && mkdir -p build-phone
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build-phone -allowProvisioningUpdates -quiet \
  CURRENT_PROJECT_VERSION="$BUILD_NUM" build 2>&1 | grep -E "error:|BUILD FAILED" || true

APP=$(find build-phone/Build/Products -maxdepth 2 -name '*.app' | head -1)
[[ -n $APP ]] || { echo "no .app produced; run the build without -quiet to see why"; exit 1; }

echo "▸ installing on $UDID"
for attempt in 1 2 3; do
  if xcrun devicectl device install app --device "$UDID" "$APP" >/dev/null 2>&1; then break; fi
  [[ $attempt == 3 ]] && { echo "the install failed three times: is the phone unlocked and on this network?"; exit 1; }
  sleep 5
done
if ! launched=$(xcrun devicectl device process launch --device "$UDID" "$BUNDLE_ID" 2>&1); then
  if grep -q "Locked" <<<"$launched"; then
    echo "note: installed but not launched: the phone is locked; unlock it and tap the app"
  else
    echo "note: the launch did not confirm: $(grep -m1 -iE 'unable|error' <<<"$launched" | sed 's/^ *//' | cut -c1-160)"
  fi
fi

have=$(xcrun devicectl device info apps --device "$UDID" 2>/dev/null | awk -v b="$BUNDLE_ID" '$0 ~ b {print $NF}')
rm -rf build-phone
echo "▸ the phone reports $BUNDLE_ID bundle version ${have:-unknown} (built $BUILD_NUM)"
[[ $have == "$BUILD_NUM" ]] || { echo "mismatch: the phone does not report the build just made"; exit 1; }
