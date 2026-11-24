#!/usr/bin/env bash
set -euo pipefail
: "${APP_CONFIG:?}" "${SOURCE_SHA:?}" "${RUNNER_TEMP:?}" "${ARTIFACT_AGE_RECIPIENT:?}" "${GITHUB_RUN_NUMBER:?}"
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
field() { python3 -c 'import json,os,sys; print(json.loads(os.environ["APP_CONFIG"])[sys.argv[1]])' "$1"; }
scheme=$(field scheme) project=$(field project)
bash "$here/prepare.sh"
build_number="$((GITHUB_RUN_NUMBER + $(python3 "$here/config.py" "$root"))).${GITHUB_RUN_ATTEMPT:-1}"
source "$here/cache-args.sh"
cd "$root/ios"
mkdir -p "$RUNNER_TEMP/output"
xcodebuild archive \
  -project "$project" -scheme "$scheme" -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$RUNNER_TEMP/output/App.xcarchive" \
  -derivedDataPath "$RUNNER_TEMP/DerivedData" \
  -onlyUsePackageVersionsFromResolvedFile \
  ${cache_args[@]+"${cache_args[@]}"} \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' \
  CURRENT_PROJECT_VERSION="$build_number" \
  | tee "$RUNNER_TEMP/output/xcodebuild.log"
cache_report
echo "Build number $build_number" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
python3 "$here/package-archive.py"
