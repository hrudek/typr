# shellcheck shell=bash
# shellcheck disable=SC2034
# Sourced by build.sh and test.sh: xcodebuild arguments that keep the Swift
# package checkouts and Xcode's content-addressed compilation cache outside
# DerivedData, where typr-ci.yml restores and saves them between runs.
# The compilation cache is keyed by the content of each compile's inputs, not
# file times, so a fresh checkout still reuses unchanged modules (FluidAudio).
# TYPR_CACHE=off builds without them (the agents' local runs need neither).
cache_args=()
if [[ "${TYPR_CACHE:-on}" != off ]]; then
  cache_args=(
    -clonedSourcePackagesDirPath "$RUNNER_TEMP/SourcePackages"
    COMPILATION_CACHE_ENABLE_CACHING=YES
    COMPILATION_CACHE_CAS_PATH="$RUNNER_TEMP/CompilationCache"
  )
fi

# One line per cache for the job summary: how big each one is after the build.
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
