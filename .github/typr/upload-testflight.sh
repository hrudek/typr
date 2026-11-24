#!/usr/bin/env bash
set -euo pipefail
: "${ASC_KEY_ID:?}" "${ASC_ISSUER_ID:?}" "${ASC_PRIVATE_KEY_BASE64:?}"
[[ "$ASC_KEY_ID" =~ ^[A-Z0-9]{10}$ ]] || { echo 'Invalid API key ID'; exit 1; }
umask 077
mkdir -p "$HOME/.appstoreconnect/private_keys"
python3 - <<'PY'
import base64, os
from pathlib import Path
path = Path.home() / '.appstoreconnect/private_keys' / f'AuthKey_{os.environ["ASC_KEY_ID"]}.p8'
path.write_bytes(base64.b64decode(os.environ['ASC_PRIVATE_KEY_BASE64'], validate=True))
PY
ipa=$(find "$RUNNER_TEMP/deliverables" -name '*.ipa')
xcrun altool --upload-app --type ios --file "$ipa" --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
