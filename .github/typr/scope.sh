#!/usr/bin/env bash
# All repository paths may change. Usage: scope.sh <base-sha> <head-sha>
# Changes under .github/ need the "infra" label, so an agent cannot widen
# automation permissions unnoticed. New Markdown files need the "docs" label:
# feature notes, plans and reports belong in the PR description, not the tree.
# Env: LABELS (comma-separated).
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
docs=$(git diff --name-only --diff-filter=A "$1" "$2" -- '*.md' || true)
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
