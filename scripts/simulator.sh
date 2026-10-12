#!/usr/bin/env bash
# Print the xcodebuild destination of the simulator the tests run on: the booted
# iPhone if there is one, otherwise the first available iPhone of the newest iOS
# runtime Xcode has. One place to decide, so make build, make test and make ci agree.
set -euo pipefail
xcrun simctl list devices available -j | python3 -c '
import json, re, sys
runtimes = json.load(sys.stdin)["devices"]
def version(key):
    m = re.search(r"iOS-(\d+)-(\d+)", key)
    return (int(m.group(1)), int(m.group(2))) if m else (0, 0)
phones = []
for key, devices in runtimes.items():
    if "iOS" not in key:
        continue
    for d in devices:
        if d.get("isAvailable") and d["name"].startswith("iPhone"):
            phones.append((d["state"] == "Booted", version(key), d["name"], d["udid"]))
if not phones:
    sys.exit("no available iPhone simulator; install an iOS runtime in Xcode")
phones.sort(key=lambda p: (p[0], p[1]), reverse=True)
print("platform=iOS Simulator,id=" + phones[0][3])
'
