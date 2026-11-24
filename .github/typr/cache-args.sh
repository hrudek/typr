# shellcheck shell=bash
# shellcheck disable=SC2034
cache_args=()
if [[ "${TYPR_CACHE:-on}" != off ]]; then
  cache_args=(
    -clonedSourcePackagesDirPath "$RUNNER_TEMP/SourcePackages"
    COMPILATION_CACHE_ENABLE_CACHING=YES
    COMPILATION_CACHE_CAS_PATH="$RUNNER_TEMP/CompilationCache"
  )
fi

cache_report() {
  [[ "${TYPR_CACHE:-on}" != off ]] || return 0
  local dir
  {
    echo '| Cache | Size |'; echo '|---|---|'
    for dir in "$RUNNER_TEMP/SourcePackages" "$RUNNER_TEMP/CompilationCache" \
               "$RUNNER_TEMP/DerivedData/CompilationCache.noindex"; do
      [[ -d "$dir" ]] && echo "| ${dir#"$RUNNER_TEMP"/} | $(du -sh "$dir" | cut -f1) |"
    done
  } >> "${GITHUB_STEP_SUMMARY:-/dev/null}" || true
}
