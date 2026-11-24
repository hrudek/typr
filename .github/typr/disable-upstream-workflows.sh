#!/usr/bin/env bash
# Usage: disable-upstream-workflows.sh <pushed sha>   (GH_TOKEN with actions: write)
# Disables every active workflow that is not typr-*, then cancels runs it started for the push.
set -euo pipefail
repo=${GITHUB_REPOSITORY:?}
typr='^\.github/workflows/typr-[^/]+\.ya?ml$'
gh api "repos/$repo/actions/workflows" --paginate \
  --jq ".workflows[] | select(.state == \"active\" and (.path | startswith(\".github/workflows/\")) and (.path | test(\"$typr\") | not)) | \"\(.id) \(.path)\"" \
  | while read -r id path; do
      echo "::warning::Disabling new upstream workflow $path"
      gh api -X PUT "repos/$repo/actions/workflows/$id/disable"
    done
for attempt in 1 2 3; do
  sleep 20
  gh api "repos/$repo/actions/runs?head_sha=$1&per_page=100" \
    --jq ".workflow_runs[] | select(.status != \"completed\" and (.path | test(\"$typr\") | not)) | \"\(.id) \(.path)\"" \
    | while read -r id path; do
        echo "Cancelling run $id of $path (attempt $attempt)"
        gh api -X POST "repos/$repo/actions/runs/$id/cancel" >/dev/null || true
      done
done
