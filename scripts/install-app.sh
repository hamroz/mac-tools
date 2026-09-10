#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
SOURCE_APP="$PROJECT_DIR/.build/app/Mac Tools.app"
INSTALLED_APP="/Applications/Mac Tools.app"

"$SCRIPT_DIR/build-app.sh"
# Preserve a previous installation before replacing it; never merge bundles.
if [[ -e "$INSTALLED_APP" ]]; then
    BACKUP_DIR="$(mktemp -d "$PROJECT_DIR/.build/install-backup.XXXXXX")"
    mv "$INSTALLED_APP" "$BACKUP_DIR/Mac Tools.app"
    echo "Previous app preserved at $BACKUP_DIR/Mac Tools.app"
fi
ditto "$SOURCE_APP" "$INSTALLED_APP"
codesign --verify --deep --strict "$INSTALLED_APP"

echo "Installed Mac Tools at $INSTALLED_APP"
echo "Open it from Finder or run: open '$INSTALLED_APP'"
