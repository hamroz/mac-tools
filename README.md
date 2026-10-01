# Mac Tools

Mac Tools is a private, local-first macOS menu-bar utility designed to grow into a collection of small desktop tools. It currently bundles **Desktop Stickies** and the **Menu Bar Organizer**.

## Desktop Stickies

- Creates editable notes from the menu bar or with `Control–Option–N`.
- Keeps notes at the desktop window level, behind normal application windows.
- Restores note text, color, size, position, and display across launches.
- Includes five adaptive colors and follows the macOS light/dark appearance.
- New notes default to graphite. Drag the top strip to reposition a note; the area below it is for editing text. The grip, color menu, and close button appear only while hovering that note. Only the bottom-right resize indicator stays visible when the pointer leaves. All palettes use a solid rounded surface without a contrasting border.
- Moves closed notes to Recently Deleted; expired notes are removed at launch, hourly while running, and when opening the manager.
- Stores data only in `~/Library/Application Support/Mac Tools/notes.json`.

## Menu Bar Organizer

- Hidden icons live in a horizontal tray below the chevron. Left-click the chevron to open it; right-click for arrangement and recovery commands.
- Use **Mac Tools → Menu Bar Organizer → Settings…** to choose Hide/Show or reorder items. **Arrange in Menu Bar…** also supports native Command-dragging across the divider; finish with **Done Arranging**.
- **Missing or Removed → Restore** brings back icons disabled by macOS's Remove command. Icons are remembered across restarts, together with their Hide/Show choice. Restoring Sound or Now Playing selects Always Show in macOS Menu Bar settings. If an app disables its own icon, you may also need to enable it in that app's settings.
- Hiding and native item interaction require Accessibility. Optional Screen Recording access provides the original menu bar glyphs in the tray; app icons appear otherwise. Icon snapshots stay in memory on this Mac.
- Only the selected item is temporarily brought back when opened from the tray. Turning the tool off or quitting removes the hiding spacer and restores access.
- Some system controls have fixed placement. The event routing used for overflow items includes an undocumented macOS field and needs hands-on verification on each supported OS. See [implementation and verification](docs/menu-bar-organizer.md).

## Build and test

The project requires macOS 14 or newer and the Swift 6 command-line toolchain.

```sh
./scripts/test.sh
./scripts/build-app.sh
```

The scripts use the SDK selected by `xcode-select` (your installed Xcode). For a deliberate SDK override, set `MAC_TOOLS_SDKROOT`. A complete Xcode installation supplies the test frameworks. The package also supports `swift test` and `swift build -c release` directly.

The app bundle is written to `.build/app/Mac Tools.app` and signed with a persistent local certificate stored in the login Keychain. Rebuilds retain the same app identity. You can set `MAC_TOOLS_SIGNING_IDENTITY` to an existing developer identity instead.

To install it in Applications (quit Mac Tools first):

```sh
./scripts/install-app.sh
```

This copies the app to `/Applications/Mac Tools.app`, preserving any previous installation under `.build/install-backup.*`. Launch at Login is intentionally off by default and can be enabled from Mac Tools Settings after installation.

## Run it (no Swift knowledge needed)

Open Terminal, paste the following, and press Return:

```sh
cd /Users/rootadmin/side-projects/mac-tools
./scripts/install-app.sh
open "/Applications/Mac Tools.app"
```

Look for the stacked-squares icon in the menu bar at the top of the screen. Choose **New Note**, or press **Control–Option–N**. Mac Tools intentionally has no Dock icon. Click inside a note to type, drag its top strip to move it, and drag its edges to resize it. Hover over the top-right corner to change color or close the note. **Manage Notes** lets you restore deleted notes. Notes stay behind regular app windows.

To tidy the menu bar, enable **Menu Bar Organizer**, use **Allow Accessibility…** if access is missing, then choose Hide/Show in its Settings window. Left-click the chevron for the hidden icon tray. While Mac Tools is active, **Option–Command–M** also opens the tray and **Command–comma** opens the organizer.

Notes pin automatically: Mission Control is detected from the system's own overlay windows (the Dock's before macOS 27, WindowManager's from macOS 27), so notes disappear on the first animation frame while Command–F3 Show Desktop keeps them in place. No special permission is required for this, and there is no per-launch synchronization step.

Optionally, **Settings → Show Desktop → Enable Accessibility…** adds a fallback Dock observer. Allow **Mac Tools** under System Settings → Privacy & Security → Accessibility, press **Recheck**, then enter and exit Show Desktop once to synchronize it. The old **Mac Tools Desktop Test** permission is separate and does not cover this app. The fallback uses undocumented Dock notification names, which may change with macOS updates. When moving from the older ad-hoc build to the stable signed build, remove and re-add the installed `/Applications/Mac Tools.app` entry once. Normal rebuilds reuse the same certificate; permission checks on startup are silent. Notes keep pinning and hiding in Mission Control even with the fallback off.

If you cannot find the menu-bar icon, open Mac Tools again while it is already running; this opens Manage Notes.

After future code changes, quit Mac Tools from its menu and run the same commands again to rebuild and install it. You can open `Package.swift` in Xcode to browse and edit the source, but building the signed `.app` with the script is the easiest way to run it normally.

## Desktop behavior and recovery

By default, the same notes appear on **all desktop workspaces (Spaces)** on their chosen display; edits are shared because each is still a single note. Open **Settings → Workspaces** (also accessible using the gear in Manage Notes) to choose **One workspace per note** instead. The preference is saved and updates existing notes immediately. In either mode, notes stay behind ordinary app windows, are hidden in Mission Control, and do not join other apps' full-screen windows.

In individual-workspace mode, new notes belong to the workspace where they are created. Exact Space assignments cannot be saved through public macOS APIs; after relaunch notes return to their saved displays in the active Space. Switching from all workspaces to individual workspaces lets macOS assign each existing window to one Space; use Manage Notes to locate it. Display changes and wake events recheck placement. A missing monitor moves its notes onto the primary display.

If a notes file cannot be decoded, Mac Tools makes a uniquely named recovery copy alongside it before permitting new saves. If the copy fails, it leaves the original untouched and keeps edits in memory. Keep the app open, resolve the storage problem, and use **Try Saving Again** in Manage Notes. Never treat in-memory changes as saved when that warning is present.

## Verification

The test suite covers storage and recovery failures, deletion/restore, expiration, disconnected and resized displays, shortcut presentation and live menu updates, multiple tool registration, native window levels/flags, menu bar item identity, organizer selection persistence, hide/reveal position handling, and organizer menu wiring. Live organizer checks on macOS 26.6.2 verified real hiding, Show, reordering, the original-glyph tray, native menu activation, disable/re-enable recovery, and permission persistence across signed rebuilds. See `docs/menu-bar-organizer.md` for the evidence. Physical multi-monitor changes, full-screen transitions, concurrent menu bar managers, and desktop presentation still require separate hands-on checks; unit tests cannot prove those interactions.

For desktop presentation changes, check both workspace modes:

- **Show Desktop** (Command–F3 or a configured hot corner): notes remain editable at the saved position.
- **Mission Control** (three-finger swipe up): notes disappear on the first animation frame.
- Return to the desktop and verify typing, dragging, resizing, and normal windows covering the notes.

Pinning needs only the window probe, not Accessibility. The synchronized configuration uses desktop-icon level + 1 with `stationary`, plus two Mission Control signals: a probe of the Dock's own windows (30 Hz) and, when allowed, the AX mode observer as fallback. The probe hides notes when a full-screen Dock layer-18 window appears together with a new full-screen layer-20 window; Show Desktop creates the layer-18 window without that companion, so notes stay visible. On macOS 27, WindowManager owns these overlays instead: Mission Control and App Exposé add a full-screen layer-19 `ExposeShieldWindow`, while Show Desktop adds a layer-18 `ShowDesktopOverlay`, so the probe hides notes while the layer-19 shield is on screen (traced 2026-10-01). A live trace on 2026-09-10 confirmed the Dock signature, and the probe hides notes roughly 30 ms after the pair appears and restores them roughly 30 ms after it disappears. The AX observer still hides notes if the probe sees no matching transition. Two earlier approaches were rejected: wallpaper level + 1 with `stationary` prevented hover/editing; the exact desktop-icon level with `stationary` also prevented editing and showed notes in Mission Control. Do not ship either combination again. Unit tests cannot prove desktop interaction or timing. See `docs/show-desktop-prototype.md` for the evidence and outstanding checks.

## Architecture

`MacToolsCore` owns the persisted model, repository, hot-key presets, and display-independent geometry. The `MacTools` executable owns AppKit windows and SwiftUI views.

The Menu Bar Organizer combines per-app Accessibility discovery with status-window metadata. It groups selected items behind an expanding divider and displays a separate horizontal tray. Window-targeted events handle overflow items, and ScreenCaptureKit optionally supplies their original glyphs. Real movement is checked before saving a Hide/Show choice; polling does not repeatedly drag settled items.

Future tools implement `ToolModule` and register with `ToolRegistry` in `AppDelegate`. Tools are compiled into Mac Tools; v1 intentionally has no dynamic plugin loader, network services, accounts, analytics, or cloud synchronization.
