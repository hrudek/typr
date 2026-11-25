#!/usr/bin/env bash
set -euo pipefail
: "${RUNNER_TEMP:?}" "${ARTIFACT_AGE_RECIPIENT:?}"
python3 - <<'PY'
import os, zipfile
from pathlib import Path
root = Path(os.environ['RUNNER_TEMP'])
logs = [root / name for name in ('signing.log', 'testflight.log', 'export.log')]
logs = [path for path in logs if path.is_file()]
if logs:
    with zipfile.ZipFile(root / 'signing-diagnostics.zip', 'w', zipfile.ZIP_DEFLATED) as archive:
        for path in logs:
            archive.write(path, path.name)
PY
if [[ -f "$RUNNER_TEMP/signing-diagnostics.zip" ]]; then
  age --encrypt --recipient "$ARTIFACT_AGE_RECIPIENT" \
    --output "$RUNNER_TEMP/signing-diagnostics.zip.age" "$RUNNER_TEMP/signing-diagnostics.zip"
  rm "$RUNNER_TEMP/signing-diagnostics.zip"
fi
