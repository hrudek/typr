#!/usr/bin/env bash
# Explicit simulator research run; does not alter the default project or CI scheme.
set -euo pipefail
if [[ $# -ne 1 ]]; then
  echo "Usage: bash ios/tools/run-research-tests.sh 'platform=iOS Simulator,id=<UDID>'" >&2
  exit 2
fi
if [[ $(uname -s) != Darwin ]]; then
  echo 'Research XCTest requires macOS, Xcode and an installed iOS simulator.' >&2
  exit 2
fi
command -v xcodegen >/dev/null
command -v xcodebuild >/dev/null
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/typr-research.XXXXXX")
echo "Research project, build products and XCTest results: $work"
# Included sources resolve relative to the specs in ios/, not the temporary output.
xcodegen generate --spec "$root/ios/research.yml" --project "$work"
xcodebuild test \
  -project "$work/TyprResearch.xcodeproj" -scheme TyprResearch \
  -destination "$1" -derivedDataPath "$work/DerivedData" \
  -resultBundlePath "$work/Research.xcresult" \
  CODE_SIGNING_ALLOWED=NO
