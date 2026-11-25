#!/usr/bin/env bash
# Usage: fingerprint.sh <git-dir> <commit> <app|test>
set -euo pipefail
mode=$3
case "$mode" in app|test) ;; *) echo "Unknown fingerprint mode: $mode" >&2; exit 1 ;; esac
overlay=(.github/typr/app.json .github/typr/overlay.py .github/typr/rebrand.py .github/typr/prepare.sh .github/typr/AppIcon.icon)
test_only=(tests/fixtures/vocabulary/audio tests/fixtures/hex-words)
paths=(ios "${overlay[@]}" "${test_only[@]}")
git -C "$1" ls-tree -rz "$2" -- "${paths[@]}" \
  | while IFS= read -r -d '' entry; do
      path=${entry#*$'\t'}
      case "$path" in
        *.md|ios/docs/*|ios/benchmark/*|ios/ci_scripts/*|ios/appstoreconnect.json|ios/ExportOptions.plist) continue ;;
        ios/scripts/fetch-cleanup-model.sh) ;;
        ios/scripts/*) continue ;;
      esac
      if [[ "$mode" == app ]]; then
        case "$path" in ios/HEXMobileTests/*|tests/*) continue ;; esac
      fi
      printf '%s\0' "$entry"
    done \
  | git -C "$1" hash-object --stdin
