#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"

if [[ -n "${MAC_TOOLS_SDKROOT:-}" ]]; then
    SDKROOT="$MAC_TOOLS_SDKROOT"
else
    SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
fi
export SDKROOT
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/clang-module-cache"

cd "$PROJECT_DIR"
swift test --disable-sandbox --scratch-path "$PROJECT_DIR/.build/swiftpm-tests"
