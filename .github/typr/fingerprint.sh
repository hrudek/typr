#!/usr/bin/env bash
# Compare committed inputs without reading blobs or requiring a full clone.
# Usage: fingerprint.sh <git-dir> <commit> [app|test|pipeline]
# app: release inputs, excluding only known test-only folders.
# test: app inputs plus simulator tests and fixtures.
# pipeline (default): test inputs plus CI scripts/workflows.
set -euo pipefail
mode=${3:-pipeline}
case "$mode" in app|test|pipeline) ;; *) echo "Unknown fingerprint mode: $mode" >&2; exit 1 ;; esac
paths=(ios .github/typr/app.json)
if [[ "$mode" == pipeline ]]; then
  paths+=(.github/typr .github/workflows)
fi
# Documentation and offline tools do not enter Xcode builds.
# project.yml and unknown iOS paths remain in BOTH lanes: project configuration
# can affect archives even when it also describes tests.
git -C "$1" ls-tree -rz "$2" -- "${paths[@]}" \
  | while IFS= read -r -d '' entry; do
      path=${entry#*$'\t'}
      case "$path" in ios/tools/*|ios/*.md) continue ;; esac
      if [[ "$mode" == app ]]; then
        case "$path" in ios/TyprTests/*|ios/TestFixtures/*) continue ;; esac
      fi
      printf '%s\0' "$entry"
    done \
  | git -C "$1" hash-object --stdin
