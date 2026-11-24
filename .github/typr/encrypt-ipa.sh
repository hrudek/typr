#!/usr/bin/env bash
set -euo pipefail
: "${RUNNER_TEMP:?}" "${ARTIFACT_AGE_RECIPIENT:?}"
ipa=$(find "$RUNNER_TEMP/deliverables" -maxdepth 1 -name '*.ipa' -type f)
[[ -n "$ipa" && "$ipa" != *$'\n'* ]] || { echo 'Expected one IPA'; exit 1; }
mkdir -p "$RUNNER_TEMP/encrypted-deliverables"
age --encrypt --recipient "$ARTIFACT_AGE_RECIPIENT" \
  --output "$RUNNER_TEMP/encrypted-deliverables/$(basename "$ipa").age" "$ipa"
cp "$RUNNER_TEMP/deliverables/build.json" "$RUNNER_TEMP/encrypted-deliverables/build.json"
# Plain IPA remains only on this ephemeral runner for the optional TestFlight upload.
