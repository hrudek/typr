#!/usr/bin/env bash
# Pinned release + platform digests; no unverified brew/curl-pipe-shell install.
# If GitHub's release downloads fail (they returned HTTP 504 for hours on
# 2026-11-08 while everything else worked), build the same pinned version from
# the Go module proxy instead: the module zip must match the pinned h1 hash
# (the one sum.golang.org records), and its own go.sum pins every dependency.
set -euo pipefail
: "${RUNNER_TEMP:?}"
version=v1.3.2
# h1 module hash of filippo.io/age@v1.3.2, as recorded by sum.golang.org.
module_h1='h1:r6RSZLFSMm6rzKepZ7ZAYkKCu14f3/Me8c7uKYh7C8c='
# Go for the fallback build when the runner has none (pinned, from dl.google.com).
go_version=go1.27.3
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64)
    platform=darwin-arm64
    digest=e2020b073c44f692685a24d6abc378817eb81ffaaf49fd0531ef8565f767f2f5
    go_digest=dd3908cf20959d798c1e06ebe5b72213f0505ce01373b40ce3110975a6cd99c2 ;;
  Darwin-x86_64)
    platform=darwin-amd64
    digest=1d1e4bc66e1427edad7739ae7616157de0e79db8b6d2a1497d7d9925fb06a539
    go_digest=b6f8e931e4ab497fcde6da8ae4499a58f9d258e55c8a80824a516eae5950a750 ;;
  Linux-x86_64)
    platform=linux-amd64
    digest=cbe24006683f8eb669266162894b9a522a1af52f2665fbc63a4bb032ed26ac10
    go_digest=65efbc80fdc1fa2cd2631cad5b481777a68e8725f34e89f50fc6ac714e379b40 ;;
  *) echo 'Unsupported age tool platform' >&2; exit 1 ;;
esac
tools="$RUNNER_TEMP/age-tools"
mkdir -p "$tools"

fetch() { # url output
  curl --fail --silent --show-error --location --retry 5 --retry-all-errors --retry-delay 5 \
    "$1" --output "$2"
}

verify_sha256() { # file expected-hex
  ACTUAL_FILE="$1" EXPECTED_DIGEST="$2" python3 -I -c '
import hashlib, os
from pathlib import Path
if hashlib.sha256(Path(os.environ["ACTUAL_FILE"]).read_bytes()).hexdigest() != os.environ["EXPECTED_DIGEST"]:
    raise SystemExit("checksum mismatch: " + os.environ["ACTUAL_FILE"])
'
}

# Called in a condition, where errexit is off: every step checks its status.
# Only a failed download falls back; a digest mismatch stops the script.
install_release() {
  local archive="$tools/age.tar.gz"
  fetch "https://github.com/FiloSottile/age/releases/download/$version/age-$version-$platform.tar.gz" "$archive" || return 1
  verify_sha256 "$archive" "$digest" || { echo '::error::age release checksum mismatch' >&2; exit 1; }
  tar -xzf "$archive" -C "$tools" age/age age/age-keygen || { echo '::error::age release archive did not extract' >&2; exit 1; }
}

# A Go new enough for age's go.mod (go 1.25): PATH, then the runner's tool
# cache (macOS images keep Go there, off PATH), else the pinned download.
find_go() {
  local candidate
  while IFS= read -r candidate; do
    [[ -n "$candidate" && -x "$candidate" ]] || continue
    if "$candidate" version | grep -qE 'go1\.(2[5-9]|[3-9][0-9])'; then
      echo "$candidate"
      return 0
    fi
  done < <(command -v go || true; find "${RUNNER_TOOL_CACHE:-/nonexistent}/go" -path '*/bin/go' -type f 2>/dev/null | sort -rV)
  local archive="$tools/go.tar.gz"
  fetch "https://dl.google.com/go/$go_version.$platform.tar.gz" "$archive" >&2 || return 1
  verify_sha256 "$archive" "$go_digest" >&2 || return 1
  tar -xzf "$archive" -C "$tools" >&2 || return 1
  echo "$tools/go/bin/go"
}

install_from_module_proxy() {
  local go zip="$tools/age-module.zip" src="$tools/src"
  go=$(find_go) || { echo '::error::no verified Go for the age fallback build' >&2; return 1; }
  echo "age fallback: building with $("$go" version)" >&2
  fetch "https://proxy.golang.org/filippo.io/age/@v/$version.zip" "$zip"
  # Go's dirhash Hash1 over the module zip; a mismatch stops before any build.
  ACTUAL_ZIP="$zip" EXPECTED_H1="$module_h1" python3 -I -c '
import base64, hashlib, os, zipfile
with zipfile.ZipFile(os.environ["ACTUAL_ZIP"]) as z:
    names = sorted(n for n in z.namelist() if not n.endswith("/"))
    lines = "".join(f"{hashlib.sha256(z.read(n)).hexdigest()}  {n}\n" for n in names)
actual = "h1:" + base64.b64encode(hashlib.sha256(lines.encode()).digest()).decode()
if actual != os.environ["EXPECTED_H1"]:
    raise SystemExit("age module hash mismatch: " + actual)
'
  rm -rf "$src" && mkdir -p "$src" "$tools/age"
  (cd "$src" && unzip -q "$zip")
  # -mod=readonly: dependencies only as the verified go.sum pins them.
  (cd "$src/filippo.io/age@$version" &&
    GOFLAGS=-mod=readonly GOPROXY=https://proxy.golang.org GOSUMDB=sum.golang.org \
      GOTOOLCHAIN=local CGO_ENABLED=0 "$go" build -trimpath -o "$tools/age/" ./cmd/age ./cmd/age-keygen)
}

if ! install_release; then
  echo "::warning::age $version release download failed; building the pinned module from proxy.golang.org" >&2
  # Outside any condition, so errexit stops at the first failing step.
  install_from_module_proxy
fi
"$tools/age/age" --version >/dev/null
if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "$tools/age" >> "$GITHUB_PATH"
fi
