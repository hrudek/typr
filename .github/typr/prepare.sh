#!/usr/bin/env bash
# Shared by build.sh and test.sh: Typr identity, upstream's cleanup model, generated project.
# Mirrors ios/ci_scripts/ci_post_clone.sh (Xcode Cloud) without its package resolve.
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
