#!/usr/bin/env bash
set -euo pipefail
security delete-keychain "$RUNNER_TEMP/ios-signing.keychain-db" 2>/dev/null || true
python3 - <<'PY'
import json, os
from pathlib import Path
manifest = Path(os.environ['RUNNER_TEMP'], 'installed-profiles.json')
if manifest.exists():
    for path in json.loads(manifest.read_text()):
        Path(path).unlink(missing_ok=True)
    manifest.unlink()
PY
rm -rf "$RUNNER_TEMP/signing" "$HOME/.appstoreconnect/private_keys" \
  "$RUNNER_TEMP/input/archive.zip" "$RUNNER_TEMP/deliverables" "$RUNNER_TEMP/signed" \
  "$RUNNER_TEMP/signing.log" "$RUNNER_TEMP/testflight.log" "$RUNNER_TEMP/export.log" \
  "$RUNNER_TEMP/signing-diagnostics.zip"
