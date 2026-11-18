#!/usr/bin/env bash
# Shared release/simulator routing; callers supply the event, ref and distribution.
set -euo pipefail
zero=0000000000000000000000000000000000000000
base='' head=$AFTER sign=''
case "$EVENT" in
  push)
    [[ "$BEFORE" != "$zero" ]] && base=$BEFORE
    sign=testflight
    ;;   # Linux checks validate pipeline changes; only app changes ship
  workflow_dispatch)
    case "$DISTRIBUTION" in
      simulator) ;;
      testflight) [[ "$REF" == refs/heads/dev ]] || { echo 'TestFlight only from dev'; exit 1; }
                  sign=testflight ;;
    esac ;;
esac
test=true build=true
if [[ "$EVENT" == push && "$base" =~ ^[0-9a-f]{40}$ ]]; then
  git init -q "$RUNNER_TEMP/fp"
  if git -C "$RUNNER_TEMP/fp" fetch -q --depth=1 --filter=blob:none "$REPO" "$base" "$head"; then
    for mode in app test; do
      a=$(bash .github/typr/fingerprint.sh "$RUNNER_TEMP/fp" "$base" "$mode")
      b=$(bash .github/typr/fingerprint.sh "$RUNNER_TEMP/fp" "$head" "$mode")
      changed=true
      [[ "$a" != "$b" ]] || changed=false
      case "$mode" in app) build=$changed ;; test) test=$changed ;; esac
    done
  else
    echo 'Cannot compare app inputs; refusing a push build without a baseline.' >&2
    exit 1
  fi
fi
[[ "$build" == true ]] || sign=''
{
  echo "test=$test"
  echo "build=$build"
  echo "sign=$sign"
} >> "$GITHUB_OUTPUT"
{
  echo '### Input routing'
  echo "| | |"; echo "|---|---|"
  echo "| Commit | \`${head:0:8}\` |"
  echo "| Compared with | \`${base:0:8}\` |"
  echo "| Simulator inputs changed | $test |"
  echo "| Release inputs changed | $build |"
  echo "| Release signing mode (device workflow only) | ${sign:-nothing} |"
} >> "$GITHUB_STEP_SUMMARY"
