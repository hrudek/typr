#!/usr/bin/env bash
# Typr's Linux checks (typr-checks.yml, typr-sync.yml). Run from the repository root.
set -euo pipefail
python3 -m unittest discover -s .github/typr/tests -v
for script in .github/typr/*.sh; do bash -n "$script"; done
shellcheck -x -P .github/typr .github/typr/*.sh
go run github.com/rhysd/actionlint/cmd/actionlint@v1.7.11 -color -ignore SC2016 -ignore SC2129 .github/workflows/typr-*.yml
