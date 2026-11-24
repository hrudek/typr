#!/usr/bin/env bash
# Screenshots of the app's fixed simulator scenes (--snap-state), taken after
# test.sh with the simulator build and simulator it already made: no second build.
# Env: SCENES (comma-separated, optional extra scenes), RUNNER_TEMP.
# Writes $RUNNER_TEMP/screenshots/<scene>.png. Never fails the job for a scene.
set -euo pipefail
: "${RUNNER_TEMP:?}"
DEFAULT_SCENES=ready,keyboard-warm,keyboard-recording,full-keyboard-idle,full-keyboard-idle-dark
udid=$(cat "$RUNNER_TEMP/simulator-udid")
app=$(find "$RUNNER_TEMP/DerivedData/Build/Products" -maxdepth 2 -path '*-iphonesimulator/HEX.app' -type d | head -1)
[[ -n "$app" ]] || { echo 'No simulator build of HEX.app found'; exit 0; }
bundle=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")
out="$RUNNER_TEMP/screenshots"
mkdir -p "$out"
xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || xcrun simctl boot "$udid" || true
xcrun simctl bootstatus "$udid" -b >/dev/null
xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 \
  --cellularBars 4 --wifiBars 3 >/dev/null 2>&1 || true
xcrun simctl install "$udid" "$app"
scenes=$(printf '%s,%s' "$DEFAULT_SCENES" "${SCENES:-}" | tr ',' '\n' | sed 's/[^a-z0-9-]//g' | awk 'NF && !seen[$0]++')
for scene in $scenes; do
  xcrun simctl terminate "$udid" "$bundle" >/dev/null 2>&1 || true
  if xcrun simctl launch "$udid" "$bundle" --snap-state "$scene" >/dev/null; then
    sleep "${SETTLE_SECONDS:-8}"   # let the scene, Metal views and animations settle
    xcrun simctl io "$udid" screenshot --type=png "$out/$scene.png" >/dev/null && echo "Captured $scene"
  else
    echo "::warning::Could not launch scene $scene"
  fi
done
xcrun simctl terminate "$udid" "$bundle" >/dev/null 2>&1 || true
ls "$out"
