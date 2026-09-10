#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"

cd "$PROJECT_DIR"
if [[ -n "${MAC_TOOLS_SDKROOT:-}" ]]; then
    SDKROOT="$MAC_TOOLS_SDKROOT"
else
    SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
fi
export SDKROOT
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/clang-module-cache"

SWIFT_ARGS=(--disable-sandbox --scratch-path "$PROJECT_DIR/.build/swiftpm")
swift build -c release "${SWIFT_ARGS[@]}"
BIN_DIR="$(swift build -c release "${SWIFT_ARGS[@]}" --show-bin-path)"

APP_DIR="$PROJECT_DIR/.build/app/Mac Tools.app"
CONTENTS_DIR="$APP_DIR/Contents"

rm -rf "$APP_DIR"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
cp "$BIN_DIR/MacTools" "$CONTENTS_DIR/MacOS/MacTools"
cp "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"

"$SCRIPT_DIR/sign-app.sh" "$APP_DIR"
echo "$APP_DIR"
