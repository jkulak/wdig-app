#!/usr/bin/env bash
# What App Store Connect says about the app: the newest builds with their processing
# and beta states, the TestFlight groups and the testers. Read-only.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
# shellcheck disable=SC1091
source ship.env
[[ -n ${ASC_APP_ID:-} ]] || { echo "ASC_APP_ID is empty in ship.env: the app record does not exist yet (docs/testflight.md, step 4)"; exit 1; }
CONFIG="$HOME/.config/testflight-deploy/config"
[[ -f $CONFIG ]] || { echo "no $CONFIG; see docs/testflight.md"; exit 1; }
(
  # shellcheck disable=SC1090
  source "$CONFIG"
  export KEY_ID ISSUER_ID P8_PATH
  echo "== builds"; python3 scripts/asc.py builds "$ASC_APP_ID"
  echo "== groups"; python3 scripts/asc.py groups "$ASC_APP_ID"
  echo "== testers"; python3 scripts/asc.py testers "$ASC_APP_ID"
)
