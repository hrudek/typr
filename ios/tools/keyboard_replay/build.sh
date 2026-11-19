#!/bin/bash
# Builds keyboard-replay from the keyboard's shared sources. Prints the binary's path.
# Usage: build.sh [BUILD_DIR]   (default: ~/.cache/typr-keyboard-replay, outside every Git checkout)
set -euo pipefail

tool=$(cd "$(dirname "$0")" && pwd)
shared="$tool/../../TyprShared"
build=${1:-${XDG_CACHE_HOME:-$HOME/.cache}/typr-keyboard-replay}
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
  FullKeyboard/AccentPicker FullKeyboard/AutocorrectEngine FullKeyboard/FullKeyboardEngine
  FullKeyboard/GermanAutocorrect FullKeyboard/KeyboardBoundaryDecoder
  FullKeyboard/KeyboardBoundaryTouch FullKeyboard/KeyboardContextModel
  FullKeyboard/KeyboardDiagnostics FullKeyboard/KeyboardKeyMap FullKeyboard/KeyboardLayout
  FullKeyboard/KeyboardLearningSession FullKeyboard/KeyboardLearningStore
  FullKeyboard/KeyboardLetterMap FullKeyboard/KeyboardMultipartSegmenter
  FullKeyboard/KeyboardSuggestionWorker FullKeyboard/KeyboardTouchInput
  FullKeyboard/KeyboardUndoWindow FullKeyboard/LexiconDelivery FullKeyboard/PersonalBigramModel
  FullKeyboard/PersonalCompletionIndex FullKeyboard/PersonalTypingModel
  FullKeyboard/ProtectedPersonalLexicon FullKeyboard/ShiftStateMachine
  FullKeyboard/SpatialPrefixSearch FullKeyboard/SpatialWordDecoder FullKeyboard/SpatialWordRanking
  FullKeyboard/SwipeDecoder FullKeyboard/SwipeEncoder FullKeyboard/TouchAimDrift
  FullKeyboard/TypingLog FullKeyboard/TypingModelTypes Statistics/UsageStatistics
  Statistics/UsageStatisticsSession Statistics/UsageStatisticsStore TyprSettings DictationLanguage SpeechEngineChoice DictationFeedbackBridge DictationFeedback
)
rm -rf "$build/src" "$build/WordData"
mkdir -p "$build/src" "$build/WordData"
system_imports='UIKit|QuartzCore'
{ echo 'enum KeyboardBridge {'; grep -m1 ' static let appGroup = ' "$shared/KeyboardBridge.swift"; echo '}'; } \
  > "$build/src/KeyboardBridge.swift"
[ "$(uname)" = Darwin ] || system_imports='UIKit|QuartzCore|CoreGraphics|Darwin'
for name in "${sources[@]}"; do
  sed -E "s/^import ($system_imports)\$/import Foundation/" "$shared/$name.swift" > "$build/src/${name##*/}.swift"
done
# AccentPicker.swift ends in its UIView; the engine needs only the catalog and menu above it.
sed -i '\#^/// Floating callout view#,$d' "$build/src/AccentPicker.swift"
if [ "$(uname)" != Darwin ]; then
  # swift-corelibs-foundation does not bridge String to CFString.
  sed -i -E -e 's/^import Foundation$/import Foundation\nimport Glibc/' \
    -e 's/CFNotificationName\(([A-Za-z.]+) as CFString\)/\1 as CFString/' \
    -e 's/([A-Za-z.]+) as CFString/CFStringCreateWithCString(nil, \1, CFStringBuiltInEncodings.UTF8.rawValue)/' \
    "$build/src/KeyboardLearningStore.swift" "$build/src/UsageStatisticsStore.swift" \
    "$build/src/DictationFeedbackBridge.swift"
fi
cp "$tool"/Sources/*.swift "$build/src/"
cp "$shared"/FullKeyboard/WordData/keyboard-{de,en}.{words,tbg} "$build/WordData/"

"${swiftc[@]}" -O -swift-version 6 "$build"/src/*.swift -o "$build/keyboard-replay" >&2
echo "$build/keyboard-replay"
