#!/usr/bin/env bash
# For agents on a Mac: run the simulator tests exactly as CI does, on a copy of the
# working tree, so Typr's identity overlay never rewrites the checkout.
# Usage: bash .github/typr/agent-test.sh [Target/Class,...]
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
copy=$(mktemp -d)
trap 'rm -rf "$copy"' EXIT
rsync -a --exclude .git --exclude target --exclude android --exclude site --exclude node_modules \
  "$root/" "$copy/"
APP_CONFIG=$(python3 "$here/config.py" | tail -1)
export APP_CONFIG ONLY_TESTING="${1:-}"
export RUNNER_TEMP="${RUNNER_TEMP:-$(mktemp -d)}" TYPR_CACHE="${TYPR_CACHE:-off}"
bash "$copy/.github/typr/select-xcode.sh"
bash "$copy/.github/typr/test.sh"
