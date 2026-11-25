#!/usr/bin/env bash
set -euo pipefail
: "${ARTIFACT_AGE_IDENTITY:?Missing private artifact identity}" "${RUNNER_TEMP:?}"
umask 077
identity=$(mktemp "$RUNNER_TEMP/artifact-identity.XXXXXX")
trap 'rm -f "$identity"' EXIT
printf '%s\n' "$ARTIFACT_AGE_IDENTITY" > "$identity"
unset ARTIFACT_AGE_IDENTITY
age --decrypt --identity "$identity" --output "$2" "$1"
