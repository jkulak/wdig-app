#!/usr/bin/env bash
# Build the app, or build it and run the unit tests, on a simulator.
# Usage: scripts/test.sh build|test [extra xcodebuild settings]
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
ACTION=${1:-test}
shift || true
DESTINATION=${DESTINATION:-$(./scripts/simulator.sh)}
RESULTS=()
if [[ $ACTION == test ]]; then
  # One fixed result bundle, so the gate can read the counts instead of parsing the log.
  rm -rf build-sim/TestResults.xcresult
  RESULTS=(-resultBundlePath build-sim/TestResults.xcresult)
fi
exec xcodebuild "$ACTION" \
  -project WDIG.xcodeproj \
  -scheme WDIG \
  -destination "$DESTINATION" \
  -derivedDataPath build-sim \
  "${RESULTS[@]}" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO \
  "$@"
