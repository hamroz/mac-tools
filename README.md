# Mac Tools

Mac Tools is a private, local-first macOS menu-bar utility designed to grow into a collection of small desktop tools. Its first bundled tool is **Desktop Stickies**.

## Desktop Stickies

- Creates editable notes from the menu bar or with `Control–Option–N`.
- Keeps notes at the desktop window level, behind normal application windows.
- Restores note text, color, size, position, and display across launches.
- Includes five adaptive colors and follows the macOS light/dark appearance.
- New notes default to graphite. Drag the top strip to reposition a note; the area below it is for editing text. The grip, color menu, and close button appear only while hovering that note. Only the bottom-right resize indicator stays visible when the pointer leaves. All palettes use a solid rounded surface without a contrasting border.
- Moves closed notes to Recently Deleted; expired notes are removed at launch, hourly while running, and when opening the manager.
- Stores data only in `~/Library/Application Support/Mac Tools/notes.json`.

## Build and test

The project requires macOS 14 or newer and the Swift 6 command-line toolchain.

```sh
./scripts/test.sh
./scripts/build-app.sh
```

The scripts use the SDK selected by `xcode-select` (your installed Xcode). For a deliberate SDK override, set `MAC_TOOLS_SDKROOT`. A complete Xcode installation supplies the test frameworks. The package also supports `swift test` and `swift build -c release` directly.

The app bundle is written to `.build/app/Mac Tools.app` and ad-hoc signed for local use.

To install it for the current user:

```sh
./scripts/install-app.sh
```

This copies the app to `~/Applications/Mac Tools.app`. Launch at Login is intentionally off by default and can be enabled from Mac Tools Settings after installation.

## Run it (no Swift knowledge needed)

Open Terminal, paste the following, and press Return:

```sh
cd /Users/rootadmin/side-projects/mac-tools
./scripts/install-app.sh
open "$HOME/Applications/Mac Tools.app"
```

Look for the stacked-squares icon in the menu bar at the top of the screen. Choose **New Note**, or press **Control–Option–N**. Mac Tools intentionally has no Dock icon. Click inside a note to type, drag its top strip to move it, and drag its edges to resize it. Hover over the top-right corner to change color or close the note. **Manage Notes** lets you restore deleted notes. Notes stay behind regular app windows; show the desktop to see them.

If you cannot find the menu-bar icon, open Mac Tools again while it is already running; this opens Manage Notes.

After future code changes, quit Mac Tools from its menu and run the same commands again to rebuild and install it. You can open `Package.swift` in Xcode to browse and edit the source, but building the signed `.app` with the script is the easiest way to run it normally.

## Desktop behavior and recovery

Notes appear in one Space at a time. Exact Space assignments cannot be saved through public macOS APIs; after relaunch notes return to their saved displays in the active Space. Display changes and wake events recheck placement. A missing monitor moves its notes onto the primary display.

If a notes file cannot be decoded, Mac Tools makes a uniquely named recovery copy alongside it before permitting new saves. If the copy fails, it leaves the original untouched and keeps edits in memory. Keep the app open, resolve the storage problem, and use **Try Saving Again** in Manage Notes. Never treat in-memory changes as saved when that warning is present.

## Verification

The test suite covers storage and recovery failures, deletion/restore, expiration, disconnected and resized displays, shortcut presentation and live menu updates, multiple tool registration, and native window levels/flags. Physical multi-monitor changes, Mission Control, Stage Manager, and login approval still need manual checks on your Mac; unit tests cannot prove those desktop interactions.

## Architecture

`MacToolsCore` owns the persisted model, repository, hot-key presets, and display-independent geometry. The `MacTools` executable owns AppKit windows and SwiftUI views.

Future tools implement `ToolModule` and register with `ToolRegistry` in `AppDelegate`. Tools are compiled into Mac Tools; v1 intentionally has no dynamic plugin loader, network services, accounts, analytics, or cloud synchronization.
