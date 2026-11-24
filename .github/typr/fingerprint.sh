#!/usr/bin/env bash
# Compare committed iOS build inputs without reading blobs or requiring a full clone.
# Usage: fingerprint.sh <git-dir> <commit> <app|test>
# app: what enters the TestFlight archive. test: app inputs plus simulator tests and fixtures.
# Everything else in this upstream Hex fork (Rust, android/, site/, docs, macOS app) starts
# no macOS job. Unknown ios/ paths count conservatively in both lanes.
set -euo pipefail
mode=$3
case "$mode" in app|test) ;; *) echo "Unknown fingerprint mode: $mode" >&2; exit 1 ;; esac
# Typr's overlay: identity, icon and the steps that apply them to upstream's project.
overlay=(.github/typr/app.json .github/typr/overlay.py .github/typr/prepare.sh .github/typr/AppIcon.icon)
# Files outside ios/ that ios/project.yml pulls in (checked by test_fingerprint.py).
# ../app/AppIcon.icon is replaced by Typr's icon, so it is not an input.
test_only=(tests/fixtures/vocabulary/audio)
paths=(ios "${overlay[@]}" "${test_only[@]}")
git -C "$1" ls-tree -rz "$2" -- "${paths[@]}" \
  | while IFS= read -r -d '' entry; do
      path=${entry#*$'\t'}
      case "$path" in
        *.md|ios/docs/*|ios/benchmark/*|ios/ci_scripts/*|ios/appstoreconnect.json|ios/ExportOptions.plist) continue ;;
        ios/scripts/fetch-cleanup-model.sh) ;;
        ios/scripts/*) continue ;;  # offline generators and release helpers
      esac
      if [[ "$mode" == app ]]; then
        case "$path" in ios/HEXMobileTests/*|tests/*) continue ;; esac
      fi
      printf '%s\0' "$entry"
    done \
  | git -C "$1" hash-object --stdin
