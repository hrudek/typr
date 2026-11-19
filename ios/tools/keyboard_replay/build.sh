#!/bin/bash
# Builds keyboard-replay from the keyboard's shared sources in place. Prints the binary's path.
# Usage: build.sh [BUILD_DIR]   (default: ~/.cache/typr-keyboard-replay, outside every Git checkout)
set -euo pipefail

tool=$(cd "$(dirname "$0")" && pwd)
shared=$(cd "$tool/../../TyprShared" && pwd)
build=${1:-${XDG_CACHE_HOME:-$HOME/.cache}/typr-keyboard-replay}
case $build in /*) ;; *) build=$PWD/$build ;; esac
dir=$build
while :; do
  if [ -L "$dir" ]; then
    echo "build.sh: $build goes through the symbolic link $dir; use the real path" >&2
    exit 1
  fi
  [ "$dir" = / ] && break
  dir=$(dirname "$dir")
done
dir=$build
while [ ! -d "$dir" ]; do dir=$(dirname "$dir"); done
dir=$(cd "$dir" && pwd -P)
while :; do
  if [ -e "$dir/.git" ]; then
    echo "build.sh: $build is inside a Git checkout; choose a directory outside it" >&2
    exit 1
  fi
  [ "$dir" = / ] && break
  dir=$(dirname "$dir")
done
mkdir -p "$build"
build=$(cd "$build" && pwd -P)

if command -v xcrun >/dev/null 2>&1; then
  swiftc=(xcrun swiftc)
elif [ -x "$HOME/.local/share/swiftly/bin/swiftc" ]; then
  swiftc=("$HOME/.local/share/swiftly/bin/swiftc")
else
  swiftc=(swiftc)
fi

sources=(
  FullKeyboard/AutocorrectEngine FullKeyboard/FullKeyboardEngine FullKeyboard/GermanAutocorrect
  FullKeyboard/KeyboardBoundaryDecoder FullKeyboard/KeyboardBoundaryTouch FullKeyboard/KeyboardContextModel
  FullKeyboard/KeyboardDiagnostics FullKeyboard/KeyboardKeyMap FullKeyboard/KeyboardLayout
  FullKeyboard/KeyboardLearningSession FullKeyboard/KeyboardLearningStore FullKeyboard/KeyboardLetterMap
  FullKeyboard/KeyboardMultipartSegmenter FullKeyboard/KeyboardSuggestionWorker FullKeyboard/KeyboardTouchInput
  FullKeyboard/KeyboardUndoWindow FullKeyboard/LexiconDelivery FullKeyboard/PersonalBigramModel
  FullKeyboard/PersonalCompletionIndex FullKeyboard/PersonalTypingModel FullKeyboard/ProtectedPersonalLexicon
  FullKeyboard/ShiftStateMachine FullKeyboard/SpatialPrefixSearch FullKeyboard/SpatialWordDecoder
  FullKeyboard/SpatialWordRanking FullKeyboard/SwipeDecoder FullKeyboard/SwipeEncoder
  FullKeyboard/TypingLog FullKeyboard/TypingModelTypes Statistics/UsageStatistics
  Statistics/UsageStatisticsSession Statistics/UsageStatisticsStore DictationFeedback DictationFeedbackBridge
  DictationLanguage SpeechEngineChoice TyprSettings FullKeyboard/FullKeyboardSettings
)
files=()
for name in "${sources[@]}"; do files+=("$shared/$name.swift"); done

# Stand-in modules for the Apple frameworks this platform lacks.
modules=(UIKit)
[ "$(uname)" = Darwin ] || modules=(CoreFoundation CoreGraphics QuartzCore Darwin UIKit)
rm -rf "$build/modules" "$build/WordData"
mkdir -p "$build/modules" "$build/WordData"
objects=()
for module in "${modules[@]}"; do
  "${swiftc[@]}" -parse-as-library -swift-version 6 -module-name "$module" -I "$build/modules" \
    -emit-module -emit-module-path "$build/modules/$module.swiftmodule" \
    -c "$tool/Shims/$module.swift" -o "$build/modules/$module.o" >&2
  objects+=("$build/modules/$module.o")
done
cp "$shared"/FullKeyboard/WordData/keyboard-{de,en}.{words,tbg} "$build/WordData/"

"${swiftc[@]}" -O -swift-version 6 -I "$build/modules" "${files[@]}" "$tool"/Sources/*.swift "${objects[@]}" \
  -o "$build/keyboard-replay" >&2
echo "$build/keyboard-replay"
