#!/usr/bin/env bash
set -euo pipefail
: "${RUNNER_TEMP:?}" "${APP_CONFIG:?}" "${APPLE_TEAM_ID:?}"
: "${IOS_CERTIFICATE_P12_BASE64:?Missing signing certificate}" "${IOS_CERTIFICATE_PASSWORD:?Missing certificate password}"
: "${IOS_PROFILES_ZIP_BASE64:?Missing provisioning profiles}"
here=$(cd "$(dirname "$0")" && pwd)
umask 077
mkdir -p "$RUNNER_TEMP/signing/profiles" "$RUNNER_TEMP/signed"
python3 - <<'PY'
import base64, io, os, stat, zipfile
from pathlib import Path
root = Path(os.environ['RUNNER_TEMP']) / 'signing'
(root / 'certificate.p12').write_bytes(base64.b64decode(os.environ['IOS_CERTIFICATE_P12_BASE64'], validate=True))
with zipfile.ZipFile(io.BytesIO(base64.b64decode(os.environ['IOS_PROFILES_ZIP_BASE64'], validate=True))) as archive:
    for entry in archive.infolist():
        if entry.is_dir():
            continue
        if stat.S_ISLNK(entry.external_attr >> 16) or entry.file_size > 5_000_000:
            raise ValueError('Invalid profile zip entry')
        path = Path(entry.filename)
        if path.is_absolute() or '..' in path.parts or path.suffix != '.mobileprovision':
            raise ValueError('Profile zip may contain only .mobileprovision files')
        target = root / 'profiles' / path.name
        if target.exists():
            raise ValueError('Duplicate profile filename')
        target.write_bytes(archive.read(entry))
PY
keychain="$RUNNER_TEMP/ios-signing.keychain-db"
password=$(openssl rand -hex 32)
echo "::add-mask::$password"
security create-keychain -p "$password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$password" "$keychain"
security import "$RUNNER_TEMP/signing/certificate.p12" -P "$IOS_CERTIFICATE_PASSWORD" \
  -k "$keychain" -T /usr/bin/codesign -T /usr/bin/security
security list-keychains -d user -s "$keychain" "$HOME/Library/Keychains/login.keychain-db"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$keychain" >/dev/null
rm "$RUNNER_TEMP/signing/certificate.p12"
# No source dependency hooks run in this job. Only trusted control scripts and Xcode.
ditto -x -k "$RUNNER_TEMP/input/archive.zip" "$RUNNER_TEMP/signing"
python3 "$here/export-options.py" \
  "$RUNNER_TEMP/signing/App.xcarchive" "$RUNNER_TEMP/signing/profiles" "$RUNNER_TEMP/signing/ExportOptions.plist"
# An unsigned archive has no signed entitlements for Xcode to preserve. Seed
# signatures with the reviewed capabilities before asking Xcode to re-export.
python3 "$here/signing-entitlements.py" seed \
  "$RUNNER_TEMP/signing/App.xcarchive" "$RUNNER_TEMP/signing/profiles" "$keychain"
xcodebuild -exportArchive -archivePath "$RUNNER_TEMP/signing/App.xcarchive" \
  -exportOptionsPlist "$RUNNER_TEMP/signing/ExportOptions.plist" \
  -exportPath "$RUNNER_TEMP/signed" | tee "$RUNNER_TEMP/export.log"
# Fail closed before publication/upload if export dropped any required capability.
while IFS= read -r -d '' ipa; do
  python3 "$here/signing-entitlements.py" verify "$ipa"
done < <(find "$RUNNER_TEMP/signed" -maxdepth 1 -name '*.ipa' -print0)
# Publish only the IPA and public provenance, never profile ZIPs, keychains or archives.
mkdir -p "$RUNNER_TEMP/deliverables"
find "$RUNNER_TEMP/signed" -maxdepth 1 -name '*.ipa' -exec cp {} "$RUNNER_TEMP/deliverables/" \;
test "$(find "$RUNNER_TEMP/deliverables" -name '*.ipa' | wc -l | tr -d ' ')" = 1
cp "$RUNNER_TEMP/input/build.json" "$RUNNER_TEMP/deliverables/build.json"
