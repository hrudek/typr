#!/usr/bin/env bash
set -euo pipefail
minimum=26.0
version_of() { /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist"; }
at_least() { [[ "$(printf '%s\n%s\n' "$minimum" "$1" | sort -V | head -1)" == "$minimum" ]]; }
if [[ -n "${XCODE_PATH:-}" ]]; then
  sudo xcode-select --switch "$XCODE_PATH/Contents/Developer"
else
  current=$(xcodebuild -version | awk 'NR==1{print $2}')
  if ! at_least "$current"; then
    newest=''
    newest_version=0
    for app in /Applications/Xcode*.app; do
      [[ -d "$app" && ! -L "$app" ]] || continue
      v=$(version_of "$app" 2>/dev/null) || continue
      if [[ "$(printf '%s\n%s\n' "$newest_version" "$v" | sort -V | tail -1)" == "$v" ]]; then
        newest=$app; newest_version=$v
      fi
    done
    echo "Default Xcode $current is older than $minimum; installed: $(printf '%s ' /Applications/Xcode*.app)"
    [[ -n "$newest" ]] && sudo xcode-select --switch "$newest/Contents/Developer"
  fi
fi
xcodebuild -version
current=$(xcodebuild -version | awk 'NR==1{print $2}')
at_least "$current" || { echo "Hex iOS requires Xcode $minimum or later"; exit 1; }
