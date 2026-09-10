#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
SOURCE_APP="$PROJECT_DIR/.build/app/Mac Tools.app"
USER_APPS_DIR="$HOME/Applications"
INSTALLED_APP="$USER_APPS_DIR/Mac Tools.app"

"$SCRIPT_DIR/build-app.sh"
mkdir -p "$USER_APPS_DIR"
ditto "$SOURCE_APP" "$INSTALLED_APP"

echo "Installed Mac Tools at $INSTALLED_APP"
echo "Open it from Finder or run: open '$INSTALLED_APP'"
