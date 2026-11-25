#!/usr/bin/env bash
# Usage: sync-resolve.sh   (inside a rebase stopped by sync.sh with exit 3)
# Claude Code edits copies of the conflicted files in a scratch folder (file tools only: no shell,
# no repository settings, hooks or MCP servers, no .git); the copies go back and sync.sh resumes.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
claude=${CLAUDE_BIN:-claude}
markers='^(<<<<<<<|\|\|\|\|\|\|\||>>>>>>>)( |$)'
for round in $(seq 1 20); do
  mapfile -t files < <(git diff --name-only --diff-filter=U)
  commit=$(git rev-parse --short REBASE_HEAD)
  echo "Round $round: Claude resolves ${files[*]} in $commit"
  work=$(mktemp -d)
  for file in "${files[@]}"; do
    mkdir -p "$work/$(dirname "$file")"
    cp "$file" "$work/$file"
  done
  git show HEAD:AGENTS.md > "$work/UPSTREAM-AGENTS.md" 2>/dev/null || true
  git show "REBASE_HEAD" -- "${files[@]}" > "$work/TYPR-COMMIT.diff"
  prompt="You are resolving a git rebase conflict for a fork of anomalyco/hex: upstream Hex plus a
small Typr layer. The Typr commits are being replayed onto the newest upstream dev.
Typr commit $commit stopped with conflicts:

$(git log -1 --format='%s%n%n%b' REBASE_HEAD | head -n 40)

This folder holds copies of the conflicted files with zdiff3 markers (ours = new upstream, the
seven-pipe section = old base, theirs = Typr):
$(printf -- '- %s\n' "${files[@]}")
TYPR-COMMIT.diff is the Typr commit's change to these files; UPSTREAM-AGENTS.md is upstream's guide.

Edit only the listed files. Remove every conflict marker so each file keeps all of the new
upstream code and re-applies the Typr commit's intent with the smallest change on the Typr side.
Never drop or rewrite upstream behaviour. If you cannot resolve a file safely, leave its markers
in place; the run then fails for a human."
  (cd "$work" && "$claude" -p "$prompt" --restricted --strict-mcp-config --tools Read,Edit,Grep,Glob \
    --permission-mode acceptEdits --model opus --output-format text) | tail -n 20
  for file in "${files[@]}"; do
    if grep -nE "$markers" "$work/$file" >&2; then
      echo "::error::Claude left conflict markers in $file"
      exit 1
    fi
    cp "$work/$file" "$file"
  done
  rm -rf "$work"
  status=0
  bash "$here/sync.sh" resume || status=$?
  [[ "$status" == 3 ]] || exit "$status"
done
echo '::error::Too many conflict rounds'
exit 1
