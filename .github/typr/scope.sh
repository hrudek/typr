#!/usr/bin/env bash
# Usage: scope.sh <base-sha> <head-sha>
set -euo pipefail
: "${LABELS:=}"
changed=$(git diff --name-only "$1" "$2")
automation=$(grep -E '^\.github/' <<<"$changed" || true)
status=0
if [[ -n "$automation" ]]; then
  if [[ ",$LABELS," == *",infra,"* ]]; then
    echo 'Automation changed (label infra present):'
  else
    echo 'Automation changed; add the "infra" label if that is intended:'
    status=1
  fi
  echo "$automation"
fi
docs=$(git diff --name-only --no-renames --diff-filter=A "$1" "$2" -- '*.md' || true)
if [[ -n "$docs" ]]; then
  if [[ ",$LABELS," == *",docs,"* ]]; then
    echo 'New Markdown files (label docs present):'
  else
    echo 'New Markdown files; put the content in the PR description, or add the "docs" label if a new file is intended:'
    status=1
  fi
  echo "$docs"
fi
count=$(printf '%s\n' "$changed" | grep -c . || true)
[[ "$status" != 0 ]] || echo "Scope OK ($count files)."
exit "$status"
