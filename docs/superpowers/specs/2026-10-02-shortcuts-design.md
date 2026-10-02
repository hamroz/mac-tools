# Shortcuts tool — design

Date: 2026-10-02
Status: approved by the user in chat (design and "go ahead" for spec, plan, and implementation)

## Purpose

A Mac Tools tool for **seeing every keyboard shortcut on this Mac** and **checking whether a combination is free to use as a new global shortcut**. View and check only: it never changes another app's settings.

Success looks like:

- One well-organized window lists global shortcuts (macOS, Mac Tools, third-party apps) and in-app menu shortcuts, grouped by where they come from, each with a short description and its owner.
- Clashes between global shortcuts are visible at a glance.
- Pressing (or building) a combination tells you immediately whether it is taken globally, reserved, only used inside some apps, or free, and suggests free alternatives with the same key.

## What was verified on this Mac

- **No API lists other apps' global hotkeys.** Registering a hotkey with `kEventHotKeyExclusive` succeeded for combos Rectangle (⌃⌥←) and Mac Tools (⌃⌥N) already hold, so a "try to register" probe cannot detect conflicts. All detection is by reading settings.
- `com.apple.symbolichotkeys` contains only shortcuts the user (or an update) has touched; missing IDs mean "macOS default". A built-in default table is required.
- Rectangle stores only overrides (`{keyCode, modifierFlags}` dicts with Cocoa flags) plus `alternateDefaultShortcuts`; defaults are implicit.
- A generic scan of `~/Library/Preferences/*.plist` finds the `KeyboardShortcuts_<name>` JSON (`carbonKeyCode`, `carbonModifiers`) used by ChatGPT, Superwhisper, LanguageTool, and `{keyCode, modifiers}` / `{keyCode, modifierFlags}` dicts (VMware Fusion, Rectangle, Accessibility).
- Real clashes on this Mac today: Rectangle "Reflow Todo" ⌃⌥N vs Desktop Stickies "New Note" ⌃⌥N; ChatGPT "Toggle launcher" ⌥Space vs Superwhisper "Toggle recording" ⌥Space.

## User-facing behavior

### Entry points

- New tool **Shortcuts** in the registry (on/off switch, its own Settings page).
- Mac Tools menu: **Show Shortcuts…** and **Check a Shortcut…**.
- Optional global shortcut to open the window: **no default** (Rectangle owns ⌃⌥ letters; global shortcuts are the user's choice).

### The Shortcuts window

A resizable window (`NavigationSplitView`) with a sidebar and a searchable detail list.

Sidebar:

1. **Check a Shortcut** (the availability checker).
2. **Global** section: **All Global**, **Conflicts** (with count), then one row per source: macOS, Mac Tools, and each third-party app that has global shortcuts. Each row shows a count.
3. **In-App** section: **Standard** (shortcuts nearly every app uses: ⌘C, ⌘Q, ⌘W…), then one row per app whose menus were captured, alphabetical, with "captured <relative time>".

Detail list rows: the keys as a monospaced pill (⌃⌥⇧⌘ order), the action, the group (macOS) or menu path (`File ▸ Export ▸ PDF`), and status badges:

- **Off**: a macOS shortcut the user turned off.
- **App not running**: the app's shortcuts only work while it runs.
- **Probably in-app**: detected in settings but shaped like a menu shortcut.
- **⚠ Clash**: another enabled global shortcut uses the same combination (tooltip names it).

Search (toolbar) matches action, app, menu path, and key display (e.g. "⌃⌥N" or "ctrl opt n").

A footer line states the limit: shortcuts from apps that grab keys at a lower level (Karabiner-Elements, BetterTouchTool, Keyboard Maestro) or store them in a private format can't be seen.

### Check a Shortcut

- A recorder field: click it, press a combination. While recording, Mac Tools' own hotkeys are not triggered (recording uses a local key monitor). Combos that another app grabs globally never reach the recorder; the field explains this and offers the builder.
- A builder: four modifier toggles (⌃ ⌥ ⇧ ⌘) plus a key picker, for combos that can't be pressed.
- The verdict, one of:
  - 🔴 **Taken globally** — lists each enabled global owner.
  - 🔴 **Standard shortcut** — e.g. ⌘C, ⌘Q; a global shortcut here would break it in every app.
  - 🔴 **Not usable globally** — no modifier (except F-keys) or Shift alone with a printable key.
  - 🟡 **Free globally, used inside apps** — lists the apps and menu items it would override while they are in front.
  - 🟢 **Free** — among the shortcuts Mac Tools can see.
- Also shown under any verdict: turned-off macOS shortcuts and "probably in-app" detected shortcuts that use the combination (informational).
- **Free alternatives**: the same key with other common global modifier sets (⌃⌥, ⌃⌘, ⌥⌘, ⌃⌥⌘, ⌃⇧⌘, ⌥⇧⌘, ⌃⌥⇧, ⌃⌥⇧⌘), each checked, free ones listed first.

### Settings page

- **Open Shortcuts window** button and an optional recorder for the window's global shortcut (no default).
- **Capture app menus automatically** (on by default): read an app's menu shortcuts when it launches.
- Accessibility status with **Enable Accessibility…** / **Recheck** (shared `AccessibilityPermission`).
- **Forget Captured Menus** (deletes the cache file).
- A "What it can see" footnote listing sources and limits.

## Sources

Every source produces `ShortcutEntry` values; the catalog merges them.

| Source | Scope | How |
|---|---|---|
| macOS system shortcuts | Global | Default table keyed by symbolic hotkey ID (name, group, default combo, default enabled), overlaid with `com.apple.symbolichotkeys` entries (`parameters[1]` = key code, `parameters[2]` = Cocoa modifier flags, `enabled`). Unknown IDs with a real combo appear as "macOS shortcut #ID". IDs for slow-motion duplicates are hidden. |
| macOS fixed shortcuts | Global | Built-in list not in that plist: ⌘Tab, ⇧⌘Tab, ⌥⌘Esc Force Quit, ⌃⌘Q Lock Screen, ⇧⌘Q Log Out, ⌥⇧⌘Q Log Out Immediately, ⌃⌘Space Emoji & Symbols. |
| Standard app shortcuts | In-App ("Standard") | Built-in list: ⌘Q, ⌘W, ⌘H, ⌥⌘H, ⌘M, ⌘, ⌘N, ⌘O, ⌘S, ⇧⌘S, ⌘P, ⌘Z, ⇧⌘Z, ⌘X, ⌘C, ⌘V, ⌘A, ⌘F, ⌘G, ⇧⌘G, ⌘T, ⌃⌘F, ⌘+, ⌘-, ⌘?. Checker treats these as "Standard shortcut". |
| Mac Tools | Global | Live: Desktop Stickies' `HotKeyManager.preset`, Text Assistant's `KeyboardShortcuts` shortcut, and Shortcuts' own window shortcut. Mac Tools' own preferences are excluded from the generic scan. |
| Rectangle | Global | If installed: the default set chosen by `alternateDefaultShortcuts` (⌃⌥ set when true, Spectacle-style ⌥⌘ set when false), overlaid with stored overrides; an empty dict means the user cleared it. Named actions ("Left Half", "Next Display", …). Its bundle ID is skipped by the generic scan. |
| Generic settings scan | Global or "probably in-app" | Every `~/Library/Preferences/*.plist` whose bundle ID resolves to an installed app (name from the app bundle). Patterns: `KeyboardShortcuts_<name>` JSON strings; dicts containing `{keyCode, modifierFlags}` (Cocoa), `{keyCode, modifiers}` (Cocoa), `{carbonKeyCode, carbonModifiers}` (Carbon), searched up to depth 3. Names are humanized (`toggleLauncher` → "Toggle launcher", `Paraphrasing_Open` → "Paraphrasing open"). A combo whose modifiers are a subset of ⇧⌘ (and whose key is not Space or an F-key) is marked "probably in-app". Sandboxed apps' container preferences are not read (that would trigger a privacy prompt). |
| User app shortcuts | In-App | `NSUserKeyEquivalents` (System Settings → Keyboard → App Shortcuts): global domain applies to all apps, per-app in each app's plist. Format `@~^$` + key. Shown under the app (or "All Apps"). |
| App menus | In-App | Accessibility: `AXMenuBar` of each running regular app (not Mac Tools), walked recursively (Apple menu skipped; depth ≤ 6; ≤ 3000 items; 1 s messaging timeout). Key from `AXMenuItemCmdVirtualKey`, else `AXMenuItemCmdGlyph`, else `AXMenuItemCmdChar`; modifiers from `AXMenuItemCmdModifiers` (⌘ implied unless bit 8; 1 = ⇧, 2 = ⌥, 4 = ⌃). Disabled items are kept. |

### Menu capture and cache

- Captured when the window opens (all running regular apps), on **Rescan**, and (if enabled) ~3 s after an app launches.
- Cached at `~/Library/Application Support/Mac Tools/Shortcuts/menu-shortcuts.json`: per bundle ID, app name, capture date, and items (`path`, `title`, `combo`). Atomic writes. A newer capture replaces the app's entry. Apps no longer installed are dropped on load.
- Without Accessibility, capture is skipped and the In-App section shows a call to action; cached data still shows.

## Architecture

Pure logic in `MacToolsCore` (unit-tested); AppKit, Accessibility, and UI in `MacTools`.

### MacToolsCore (`Sources/MacToolsCore/Shortcuts/`)

- `KeyCombo.swift` — `ShortcutModifiers` (OptionSet: control, option, shift, command, function) and `KeyCombo { keyCode: UInt16, modifiers }`, `Hashable, Codable, Sendable`. Initializers from Carbon modifiers, Cocoa flags, AX menu modifiers, and user-key-equivalent strings. `displayString` (⌃⌥⇧⌘ order, `fn` prefix when set). `KeyNames`: key code ↔ display name (US ANSI layout: letters, digits, punctuation, arrows, F1–F20, Return, Tab, Space, Delete, Esc, Home/End/Page keys, keypad) and character → key code, plus menu glyph code → key code.
- `ShortcutEntry.swift` — `ShortcutScope { global, inApp }`, `ShortcutSource { id, name, kind: system | standard | macTools | app(bundleID) }`, `ShortcutEntry { id, combo, action, detail (group or menu path), source, scope, isEnabled, isProbablyInApp, isSourceRunning }`.
- `MacOSShortcuts.swift` — the default table, fixed list, standard list, and `entries(symbolicHotKeys: [String: Any]) -> [ShortcutEntry]`.
- `RectangleShortcuts.swift` — default sets and `entries(preferences: [String: Any]) -> [ShortcutEntry]`.
- `PreferenceShortcutScanner.swift` — `entries(bundleID:appName:preferences:)` for the generic patterns; `userKeyEquivalents(...)`; `humanize(_:)`.
- `MenuShortcutCache.swift` — `CapturedApp { bundleID, name, capturedAt, items: [MenuShortcut] }`, `MenuShortcut { path: [String], title, combo }`, and `MenuShortcutCacheStore` (load/save/forget a JSON file at an injectable URL).
- `ShortcutCatalog.swift` — holds entries; `globalConflicts` (enabled, non-"probably in-app" global entries sharing a combo, from different actions); `entries(matching search:)`.
- `ShortcutChecker.swift` — `ShortcutVerdict` (`takenGlobally`, `standard`, `notUsable(reason)`, `usedInApps`, `free`) plus informational matches; `alternatives(for:)`.

### MacTools (app)

- `ShortcutsModule.swift` — `ToolModule` (`id: "shortcuts"`, name "Shortcuts", symbol `command.square.fill`, tint `.indigo`). Menu items; app-launch observer for auto capture; optional window shortcut via `KeyboardShortcuts` (`.shortcutsShowWindow`, no default).
- `ShortcutsStore.swift` — `@MainActor ObservableObject`: gathers sources off the main thread, publishes `ShortcutCatalog`, running-app state, capture progress; owns the cache store and menu reader. Gets Mac Tools' live shortcuts through an injected closure so it doesn't depend on other modules.
- `MenuShortcutReader.swift` — Accessibility walk for one `NSRunningApplication`, returning `CapturedApp`.
- `ShortcutsWindow.swift` — window controller and browse views (sidebar, list, rows, badges).
- `ShortcutCheckView.swift` — recorder, builder, verdict, alternatives.
- `ShortcutsSettingsView.swift` — Settings page sections.
- `AppDelegate` registers the module; Desktop Stickies exposes its `HotKeyManager` preset read-only for the live Mac Tools source.

## Error handling

- Unreadable or malformed plists are skipped silently; one bad file never hides other sources.
- Accessibility calls that fail or time out skip that app (or subtree) and keep the rest; the capture progress shows the count captured.
- Cache file corruption: treated as empty and overwritten on next capture.
- All scanning runs off the main thread; the window stays responsive and shows "Scanning…".

## Testing

- Core unit tests with fixture dictionaries: key code/modifier conversions and display; symbolic hotkey overlay (default, override, disabled, unknown ID); Rectangle defaults + overrides + cleared; generic scan patterns, humanizing, "probably in-app" rule; user key equivalents parsing; cache round trip; catalog conflicts (including the two real clashes); checker verdicts for each case and alternatives.
- App tests: module appears in the registry and builds its menu items; menu reader against Finder (skipped when the test runner lacks Accessibility).
- Manual: build, install, open the window, confirm real data and the two known clashes, try the checker with ⌃⌥N, ⌥Space, ⌘C, ⌃⌥⌘J.

## Out of scope

- Editing, disabling, or rebinding any shortcut.
- Reading sandboxed apps' container preferences, event-tap tools' private configs, and non-US keyboard layout key names.
- Per-app adapters beyond Rectangle (the source structure allows adding them later).
