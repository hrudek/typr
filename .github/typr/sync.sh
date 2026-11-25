#!/usr/bin/env bash
# Usage: sync.sh plan <dev> <upstream>   → start, upstream, base, noop
#        sync.sh rebase                  → rebases START's Typr commits onto UPSTREAM
#        sync.sh resume                  → continues after conflicts were resolved
# rebase/resume exit 3 when conflicts other than AGENTS.md remain (listed in `conflicts`).
set -euo pipefail
out=${GITHUB_OUTPUT:-/dev/null}

in_rebase() { [[ -d "$(git rev-parse --git-path rebase-merge)" ]]; }

drive() {
  local rounds=0
  while in_rebase; do
    (( ++rounds <= 500 )) || { echo 'Rebase does not advance' >&2; exit 1; }
    mapfile -t files < <(git diff --name-only --diff-filter=U)
    if printf '%s\n' "${files[@]}" | grep -qx AGENTS.md; then
      echo 'AGENTS.md conflict: keeping the Typr version'
      git checkout --theirs -- AGENTS.md
      git add AGENTS.md
      mapfile -t files < <(git diff --name-only --diff-filter=U)
    fi
    if (( ${#files[@]} )); then
      echo "Conflicts in $(git rev-parse --short REBASE_HEAD) $(git log -1 --format=%s REBASE_HEAD):"
      printf '  %s\n' "${files[@]}"
      echo "conflicts=${files[*]}" >> "$out"
      exit 3
    fi
    if git diff --cached --quiet; then
      GIT_EDITOR=true git rebase --skip || true
    else
      GIT_EDITOR=true git rebase --continue || true
    fi
  done
  [[ "$(git rev-parse HEAD)" != "$START" ]] || { echo 'Rebase produced no new head' >&2; exit 1; }
  mapfile -t typr < <(git diff --name-only "$UPSTREAM" HEAD)
  if (( ${#typr[@]} )) && git grep -nE '^(<<<<<<<|>>>>>>>) ' HEAD -- "${typr[@]}" >&2; then
    echo 'Conflict markers left in Typr files' >&2
    exit 1
  fi
  echo "head=$(git rev-parse HEAD)" >> "$out"
  echo "Rebased $(git rev-list --count "$UPSTREAM..HEAD") Typr commit(s) onto ${UPSTREAM:0:8}"
}

case "${1:-}" in
  plan)
    from=$(git rev-parse "$2^{commit}") onto=$(git rev-parse "$3^{commit}")
    base=$(git merge-base "$from" "$onto")
    noop=false
    [[ "$base" != "$onto" ]] || noop=true
    printf 'start=%s\nupstream=%s\nbase=%s\nnoop=%s\n' "$from" "$onto" "$base" "$noop" | tee -a "$out"
    echo "Typr commits: $(git rev-list --count "$base..$from"), new upstream commits: $(git rev-list --count "$base..$onto")"
    ;;
  rebase)
    : "${START:?}" "${UPSTREAM:?}"
    base=$(git merge-base "$START" "$UPSTREAM")
    git switch -q -C typr-sync "$START"
    git config merge.conflictStyle zdiff3
    git rebase -q --no-keep-empty --onto "$UPSTREAM" "$base" || in_rebase || exit 1
    drive
    ;;
  resume)
    : "${START:?}" "${UPSTREAM:?}"
    git add -u
    drive
    ;;
  *) sed -n '2,5p' "$0" >&2; exit 2 ;;
esac
