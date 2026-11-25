#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
python3 "$here/overlay.py" "$root"
cd "$root/ios"
command -v xcodegen >/dev/null || brew install xcodegen
xcodegen --version
sh scripts/fetch-cleanup-model.sh
xcodegen generate
pins=HEXMobile.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
mkdir -p "$pins"
cp Package.resolved "$pins/Package.resolved"
