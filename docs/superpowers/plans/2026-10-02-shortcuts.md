# Shortcuts Tool Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Mac Tools tool that lists every global and in-app keyboard shortcut on the Mac and checks whether a combination is free as a global shortcut.

**Architecture:** Pure parsing, catalog, and checking logic lives in `MacToolsCore/Shortcuts/` and is unit-tested with fixture dictionaries. The app target adds an Accessibility menu reader, an `ObservableObject` store that gathers all sources off the main thread, a SwiftUI window (browse + check), a Settings page, and a `ToolModule` registered in `AppDelegate`.

**Tech Stack:** Swift 6, SwiftUI + AppKit, Accessibility (`AXUIElement`), `KeyboardShortcuts` (already a dependency), XCTest.

**Spec:** `docs/superpowers/specs/2026-10-02-shortcuts-design.md`

## Global Constraints

- macOS 14+, Swift 6 strict concurrency; no new package dependencies.
- View and check only: never write another app's preferences.
- New global shortcuts have **no default** (the window shortcut `.shortcutsShowWindow`).
- Tool descriptor: `id: "shortcuts"`, name `"Shortcuts"`, symbol `command.square.fill`, tint `.indigo`.
- Cache path: `~/Library/Application Support/Mac Tools/Shortcuts/menu-shortcuts.json`, atomic writes.
- Do not read `~/Library/Containers/*` (privacy prompt).
- Key display order ⌃⌥⇧⌘, `fn` prefix when the function flag is set; US ANSI key names.
- Copy: verdict wording "Free" means "among the shortcuts Mac Tools can see"; the window footer names Karabiner-Elements, BetterTouchTool, Keyboard Maestro as unseen.
- Tests: `./scripts/test.sh`. Build: `./scripts/build-app.sh`.

## Review Focus

- Malformed plist values (wrong types, `keyCode` as String, negative numbers, huge numbers) — skipped, never crash. Test in Task 3.
- `com.apple.symbolichotkeys` entries with key code 65535 / no parameters — treated as "no shortcut", not a combo. Test in Task 2.
- Corrupt or missing cache JSON — loads as empty. Test in Task 4.
- The same action reported twice (e.g. a Rectangle key that also matches the generic scan) — not reported as a clash with itself. Test in Task 5 (catalog dedupes by source + combo + action) and Task 3 (Rectangle bundle ID skipped by the generic scan).
- Menu items whose key char is not in the ANSI map (e.g. "€") — skipped from capture rather than producing a wrong key. Test in Task 1 (`KeyNames.keyCode(forCharacter:)` returns nil).

---

### Task 1: KeyCombo, modifiers, key names

**Files:**
- Create: `Sources/MacToolsCore/Shortcuts/KeyCombo.swift`
- Test: `Tests/MacToolsCoreTests/KeyComboTests.swift`

**Interfaces:**
- Produces:
  - `public struct ShortcutModifiers: OptionSet, Hashable, Codable, Sendable` with `.control .option .shift .command .function`; `init(carbon: Int)` (cmd 256, shift 512, option 2048, control 4096); `init(cocoa: Int)` (shift 0x20000, control 0x40000, option 0x80000, command 0x100000, function 0x800000); `init(axMenu: Int)` (⌘ unless bit 8; 1 ⇧, 2 ⌥, 4 ⌃); `var symbols: String`.
  - `public struct KeyCombo: Hashable, Codable, Sendable, Comparable { keyCode: UInt16; modifiers: ShortcutModifiers }`; `init?(userKeyEquivalent: String)` parses `@~^$` + key; `var displayString: String`; `var searchText: String` (display + words "ctrl opt shift cmd fn" + key name).
  - `public enum KeyNames { static func name(for keyCode: UInt16) -> String; static func keyCode(forCharacter: String) -> UInt16?; static func keyCode(forMenuGlyph: Int) -> UInt16?; static func isFunctionKey(_:) -> Bool; static var pickerKeys: [UInt16] }`.

- [ ] **Step 1: Write failing tests** — `test_carbonAndCocoaModifiersMatch` (`ShortcutModifiers(carbon: 2048) == [.option]`, `ShortcutModifiers(cocoa: 786432) == [.control, .option]`, `ShortcutModifiers(cocoa: 1179648) == [.command, .shift]`); `test_axMenuModifiers` (`0 → [.command]`, `1 → [.command,.shift]`, `8 → []`, `12 → [.control]`); `test_displayString` (`KeyCombo(45, [.control,.option]).displayString == "⌃⌥N"`, `KeyCombo(49, [.option]) == "⌥Space"`, `KeyCombo(123, [.control]) == "⌃←"`, `KeyCombo(122, [.control,.function]) == "fn⌃F1"`); `test_userKeyEquivalent` (`"@$k" → ⇧⌘K`, `"^~\u{F702}"` → ⌃⌥←, `"" → nil`); `test_characterLookup` (`"s" → 1`, `"S" → 1`, `"," → 43`, `"€" → nil`); `test_menuGlyph` (`100 → 123` left arrow, `0x6F → 122` F1).
- [ ] **Step 2: Run `./scripts/test.sh --filter KeyComboTests`** — expect compile failure.
- [ ] **Step 3: Implement** with static key-code tables (ANSI letters/digits/punctuation, arrows 123–126, F1–F20 codes, Return 36, Tab 48, Space 49, Delete 51, Esc 53, Forward Delete 117, Home 115, End 119, Page Up 116, Page Down 121, keypad). Menu glyphs: 0x64 ←, 0x65 →, 0x68 ↑, 0x6A ↓, 0x6F–0x7A and 0x87–0x8A F1–F15, 0x04/0x0B Return/Enter, 0x02 Tab, 0x17 Delete, 0x0A Forward Delete, 0x1B Esc, 0x09 Space, 0x62 Page Up, 0x6B Page Down, 0x66 Home, 0x67 End. Function-key unicode in key equivalents: `\u{F700}`–`\u{F703}` arrows, `\u{F704}`+ F-keys.
- [ ] **Step 4: Run tests** — PASS.
- [ ] **Step 5: Commit** `feat(shortcuts): key combos and key names`.

### Task 2: Entries and macOS sources

**Files:**
- Create: `Sources/MacToolsCore/Shortcuts/ShortcutEntry.swift`, `Sources/MacToolsCore/Shortcuts/MacOSShortcuts.swift`
- Test: `Tests/MacToolsCoreTests/MacOSShortcutsTests.swift`

**Interfaces:**
- Consumes: Task 1.
- Produces:
  - `public enum ShortcutScope: String, Codable, Sendable { case global, inApp }`
  - `public struct ShortcutSource: Hashable, Sendable { id: String; name: String; kind: Kind }`, `enum Kind: Hashable, Sendable { case system, standard, macTools, app(bundleID: String) }`, statics `.macOS`, `.standard`, `.macTools`, `static func app(bundleID:name:)`.
  - `public struct ShortcutEntry: Identifiable, Hashable, Sendable { id: String; combo: KeyCombo; action: String; detail: String?; source: ShortcutSource; scope: ShortcutScope; isEnabled: Bool; isProbablyInApp: Bool; isSourceRunning: Bool }` (memberwise init with defaults `detail: nil, isEnabled: true, isProbablyInApp: false, isSourceRunning: true`; `id` = `"\(source.id)|\(scope)|\(detail ?? "")|\(action)|\(combo)"`).
  - `public enum MacOSShortcuts { static func entries(symbolicHotKeys: [String: Any]) -> [ShortcutEntry]; static let fixed: [ShortcutEntry]; static let standard: [ShortcutEntry] }`.

- [ ] **Step 1: Write failing tests** — `test_defaultsAppearWhenPlistIsEmpty` (empty dict → contains "Save picture of screen as a file" ⇧⌘3 group "Screenshots" enabled; "Show Spotlight search" ⌘Space); `test_overrideReplacesDefault` (`["64": ["enabled": true, "value": ["parameters": [32, 49, 1572864]]]]` → Spotlight is ⌥⌘Space); `test_disabledEntryKeptAsOff` (`"64"` enabled false → `isEnabled == false`); `test_noKeyMeansNoEntry` (`"160"` params `[65535, 65535, 0]` → no Launchpad entry); `test_unknownIDWithComboAppears` (`"999"` params `[97, 0, 1048576]` → action `"macOS shortcut #999"`); `test_slowMotionDuplicatesHidden` (`"34"` → nothing); `test_fixedAndStandardLists` (fixed contains ⌥⌘Esc "Force Quit"; standard contains ⌘C "Copy" with scope `.inApp`, source `.standard`).
- [ ] **Step 2: Run** — fails.
- [ ] **Step 3: Implement** the default table (ID → name, group, default combo, default enabled): 7–13, 57 (Keyboard navigation, ⌃F1–⌃F8 with fn flag), 15/17/19/21/23/25/26 (Accessibility zoom/invert/contrast), 27 "Move focus to next window" ⌘`, 28/29/30/31/184 (Screenshots), 32/33/36/79/81 (Mission Control; Show Desktop F11), 118–133 "Switch to Desktop N" ⌃N disabled by default (keys 1–9 then none), 52 Dock hiding ⌥⌘D, 59 VoiceOver ⌘F5, 162 Accessibility controls ⌥⌘F5, 60/61 input sources (⌃Space, ⌃⌥Space), 64/65 Spotlight, 98 Help menu ⇧⌘/, 160/163/175/190 named without default combo (190 "Quick Note" fn Q). Hidden IDs: 34, 35, 37, 80, 82, 164. Plist overlay: parameters[1] key code (65535 = none), parameters[2] Cocoa flags; non-numeric parameters → skip.
- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `feat(shortcuts): macOS shortcut sources`.

### Task 3: Rectangle and the generic preferences scan

**Files:**
- Create: `Sources/MacToolsCore/Shortcuts/RectangleShortcuts.swift`, `Sources/MacToolsCore/Shortcuts/PreferenceShortcutScanner.swift`
- Test: `Tests/MacToolsCoreTests/PreferenceShortcutTests.swift`

**Interfaces:**
- Consumes: Tasks 1–2.
- Produces:
  - `public enum RectangleShortcuts { static let bundleID = "com.knollsoft.Rectangle"; static func entries(preferences: [String: Any], isRunning: Bool) -> [ShortcutEntry] }`.
  - `public enum PreferenceShortcutScanner { static func entries(bundleID: String, appName: String, preferences: [String: Any], isRunning: Bool) -> [ShortcutEntry]; static func userKeyEquivalents(_ value: Any?, source: ShortcutSource) -> [ShortcutEntry]; static func humanize(_ key: String) -> String; static func isProbablyInApp(_ combo: KeyCombo) -> Bool }`.

- [ ] **Step 1: Write failing tests** — Rectangle: `test_rectangleAlternateDefaults` (`["alternateDefaultShortcuts": true]` → "Left Half" ⌃⌥←, "Maximize" ⌃⌥Return); `test_rectangleOverrideAndCleared` (`"leftHalf": ["keyCode": 0, "modifierFlags": 1572864]` → ⌥⌘A; `"maximize": [:]` → no Maximize entry; `"reflowTodo": ["keyCode": 45, "modifierFlags": 786432]` → "Reflow Todo" ⌃⌥N); `test_rectangleSpectacleDefaults` (`false` → "Left Half" ⌥⌘←). Generic: `test_keyboardShortcutsJSON` (`"KeyboardShortcuts_toggleLauncher": "{\"carbonModifiers\":2048,\"carbonKeyCode\":49}"` → "Toggle launcher" ⌥Space global, not probably-in-app); `test_cocoaDicts` (`["startMenuShortcutHotKey": ["keyCode": 49, "modifiers": 262144]]` → ⌃Space; nested at depth 2 found); `test_probablyInApp` (⌘S, ⇧⌘K → true; ⌥Space, ⌘Space, ⌘F5, ⌃⌥N → false; no-modifier ↓ → true); `test_humanize` (`"toggleLauncher" → "Toggle launcher"`, `"Paraphrasing_Open" → "Paraphrasing open"`, `"OpenInEditorShortcut" → "Open in editor shortcut"`); `test_malformedValuesSkipped` (`"keyCode": "x"`, `-1`, `70000`, JSON `"{bad"` → no entries, no crash); `test_userKeyEquivalents` (`["Export…": "@$e"]` → ⇧⌘E action "Export…" scope `.inApp`).
- [ ] **Step 2: Run** — fails.
- [ ] **Step 3: Implement.** Rectangle ⌃⌥ set (alternate = true): leftHalf ←, rightHalf →, topHalf ↑, bottomHalf ↓, topLeft U, topRight I, bottomLeft J, bottomRight K, firstThird D, centerThird F, lastThird G, firstTwoThirds E, lastTwoThirds T, maximize Return, maximizeHeight ⇧↑, smaller -, larger =, center C, restore Delete, nextDisplay ⌃⌥⌘→, previousDisplay ⌃⌥⌘←. Spectacle set (false): leftHalf ⌥⌘←, rightHalf ⌥⌘→, topHalf ⌥⌘↑, bottomHalf ⌥⌘↓, topLeft ⌃⌘←, topRight ⌃⌘→, bottomLeft ⌃⇧⌘←, bottomRight ⌃⇧⌘→, nextDisplay ⌃⌥⌘→, previousDisplay ⌃⌥⌘←, maximize ⌥⌘F, smaller ⌃⌥⇧←, larger ⌃⌥⇧→, center ⌥⌘C, restore ⌃⌥Delete. Any other plist dict with `keyCode`/`modifierFlags` is an action named by humanizing its key. Generic scan depth ≤ 3; numbers must be integral and in range (key code 0…0x7F, modifiers ≥ 0). `isProbablyInApp`: modifiers ⊆ {⇧, ⌘} and key is not Space and not an F-key.
- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `feat(shortcuts): Rectangle and preference scan sources`.

### Task 4: Menu shortcut cache

**Files:**
- Create: `Sources/MacToolsCore/Shortcuts/MenuShortcutCache.swift`
- Test: `Tests/MacToolsCoreTests/MenuShortcutCacheTests.swift`

**Interfaces:**
- Produces: `public struct MenuShortcut: Codable, Hashable, Sendable { path: [String]; title: String; combo: KeyCombo; isEnabled: Bool }`; `public struct CapturedApp: Codable, Hashable, Sendable { bundleID, name: String; capturedAt: Date; items: [MenuShortcut]; func entries(isRunning: Bool) -> [ShortcutEntry] }` (detail = `path.joined(" ▸ ")`, scope `.inApp`); `public final class MenuShortcutCacheStore: @unchecked Sendable { init(url: URL = defaultURL); static var defaultURL: URL; func load() -> [String: CapturedApp]; func save(_ apps: [String: CapturedApp]) throws; func forget() }`.

- [ ] **Step 1: Write failing tests** — `test_roundTrip` (save two apps → load equal); `test_missingOrCorruptFileLoadsEmpty` (no file → `[:]`; file `"nope"` → `[:]`); `test_forgetRemovesFile`; `test_entriesUseMenuPath` (path `["File","Export"]` → detail `"File ▸ Export"`).
- [ ] **Step 2–4:** run (fail), implement with `JSONEncoder` ISO-8601 dates and `.atomic` writes, creating the directory; run (pass).
- [ ] **Step 5: Commit** `feat(shortcuts): menu shortcut cache`.

### Task 5: Catalog and checker

**Files:**
- Create: `Sources/MacToolsCore/Shortcuts/ShortcutCatalog.swift`, `Sources/MacToolsCore/Shortcuts/ShortcutChecker.swift`
- Test: `Tests/MacToolsCoreTests/ShortcutCheckerTests.swift`

**Interfaces:**
- Produces:
  - `public struct ShortcutCatalog: Sendable { init(entries: [ShortcutEntry]); entries: [ShortcutEntry]` (deduplicated by `id`); `var globalEntries`, `var inAppEntries`; `var conflicts: [KeyCombo: [ShortcutEntry]]`; `func isConflicted(_ e: ShortcutEntry) -> Bool`; `func entries(matching query: String, in scope: [ShortcutEntry]) -> [ShortcutEntry]` (case-insensitive across action, detail, source name, `combo.searchText`; every whitespace-separated term must match) }`.
  - "Active global" = scope `.global`, `isEnabled`, `!isProbablyInApp`. A conflict = ≥ 2 active global entries with the same combo whose `(source.id, action)` differ.
  - `public struct ShortcutCheckResult: Sendable { combo; verdict: ShortcutVerdict; globalOwners, standardMatches, inAppMatches, inactiveMatches: [ShortcutEntry] }`; `public enum ShortcutVerdict: Equatable, Sendable { case takenGlobally, standard, notUsable(String), usedInApps, free }`; `public enum ShortcutChecker { static func check(_ combo: KeyCombo, in catalog: ShortcutCatalog) -> ShortcutCheckResult; static func alternatives(for combo: KeyCombo, in catalog: ShortcutCatalog) -> [ShortcutCheckResult] }`.
  - Verdict precedence: notUsable → takenGlobally → standard → usedInApps → free. notUsable: no modifiers (ignoring fn) and not an F-key → "Needs at least one modifier key"; modifiers == [.shift] and not F-key → "Shift alone types a character". `inactiveMatches` = global entries with the combo that are off or probably-in-app. Alternatives: the eight sets ⌃⌥, ⌃⌘, ⌥⌘, ⌃⌥⌘, ⌃⇧⌘, ⌥⇧⌘, ⌃⌥⇧, ⌃⌥⇧⌘ excluding the combo's own, sorted free → usedInApps → others, stable.

- [ ] **Step 1: Write failing tests** — fixture catalog with Stickies ⌃⌥N (macTools), Rectangle "Reflow Todo" ⌃⌥N, ChatGPT ⌥Space, Superwhisper ⌥Space, Standard ⌘C, Cursor menu "File ▸ Save" ⌘S, disabled macOS ⌃Space, probably-in-app ChatGPT ⌘S duplicated twice. Tests: `test_realClashesDetected` (conflicts has exactly ⌃⌥N and ⌥Space keys); `test_duplicateEntriesAreNotAClash`; `test_verdicts` (⌃⌥N → takenGlobally with 2 owners; ⌘C → standard; ⌘S → usedInApps with Cursor in inAppMatches and ChatGPT ⌘S in inactiveMatches; J no modifiers → notUsable; ⇧J → notUsable; F5 alone → free; ⌃Space → free with inactiveMatches 1; ⌃⌥⌘J → free); `test_alternativesFreeFirst` (for ⌃⌥N: first alternative is free, list has 7 items, ⌃⌥N absent); `test_search` (`"opt space"` finds both ⌥Space entries; `"reflow"` finds Rectangle).
- [ ] **Step 2–4:** run, implement, run.
- [ ] **Step 5: Commit** `feat(shortcuts): catalog conflicts and availability checker`.

### Task 6: Menu reader and store (app target)

**Files:**
- Create: `Sources/MacTools/MenuShortcutReader.swift`, `Sources/MacTools/ShortcutsStore.swift`
- Modify: `Sources/MacTools/DesktopStickiesModule.swift` (expose `var hotKeyPreset: HotKeyPreset { hotKeyManager.preset }`)
- Test: `Tests/MacToolsAppTests/ShortcutsStoreTests.swift`

**Interfaces:**
- Consumes: Tasks 1–5.
- Produces:
  - `enum MenuShortcutReader { nonisolated static func capture(pid: pid_t, bundleID: String, name: String) -> CapturedApp? }` — AX walk per spec (Apple menu skipped, depth ≤ 6, ≤ 3000 items, `AXUIElementSetMessagingTimeout` 1 s); items whose key can't be resolved are skipped.
  - `@MainActor final class ShortcutsStore: ObservableObject { @Published private(set) var catalog: ShortcutCatalog; @Published private(set) var capturedApps: [String: CapturedApp]; @Published private(set) var isScanning: Bool; @Published private(set) var lastScan: Date?; init(cache: MenuShortcutCacheStore = .init(), preferencesDirectory: URL = ~/Library/Preferences, macToolsShortcuts: @escaping @MainActor () -> [ShortcutEntry]); func refresh(captureMenus: Bool) async; func capture(app: NSRunningApplication) async; func forgetCapturedMenus() }`.
  - `refresh` reads, off the main actor: symbolichotkeys plist, `-g` `NSUserKeyEquivalents`, Rectangle, each `*.plist` in the preferences directory whose bundle ID resolves via `NSWorkspace.urlForApplication(withBundleIdentifier:)` (skipping `com.apple.*` except as above, Mac Tools' own bundle ID, and Rectangle); per-app `NSUserKeyEquivalents`; running state from `NSWorkspace.runningApplications`. Then, if `captureMenus` and Accessibility is trusted, captures every running `.regular` app except Mac Tools, merging into the cache and saving. Cached apps not installed are dropped.
- [ ] **Step 1: Write failing test** — `test_refreshBuildsCatalogFromFixtureDirectory`: temp preferences dir with `com.example.fake.plist` is ignored (not installed) and Mac Tools entries from the closure appear; `catalog.globalEntries` contains a macOS Spotlight entry; `test_forgetClearsCache`. `test_readsFinderMenus` (skip unless `AXIsProcessTrusted()`): capture Finder → has an item titled "New Folder" with ⇧⌘N.
- [ ] **Step 2–4:** run, implement, run.
- [ ] **Step 5: Commit** `feat(shortcuts): menu reader and shortcut store`.

### Task 7: Window, checker UI, settings page, module, registration, README

**Files:**
- Create: `Sources/MacTools/ShortcutsWindow.swift`, `Sources/MacTools/ShortcutCheckView.swift`, `Sources/MacTools/ShortcutsSettingsView.swift`, `Sources/MacTools/ShortcutsModule.swift`
- Modify: `Sources/MacTools/AppDelegate.swift` (register `ShortcutsModule` after Text Assistant, passing a closure that reads Stickies' preset and `KeyboardShortcuts.getShortcut(for:)` for `.textAssistantImprove` and `.shortcutsShowWindow`), `README.md` (new "Shortcuts" section; tool list sentence), `Tests/MacToolsAppTests/AppIntegrationTests.swift`
- Test: `Tests/MacToolsAppTests/AppIntegrationTests.swift`

**Interfaces:**
- Consumes: Task 6.
- Produces: `ShortcutsModule(store:settings:)` conforming to `ToolModule`; `ShortcutsSettings` (`@Published var captureMenusAutomatically: Bool`, key `shortcuts.captureMenusAutomatically`, default true); `KeyboardShortcuts.Name.shortcutsShowWindow` (no default); `ShortcutsWindowController.show(page: ShortcutsPage)` with `enum ShortcutsPage: Hashable { case check, allGlobal, conflicts, source(String), standard, app(String) }`.
- [ ] **Step 1: Write failing test** — `test_ShortcutsModuleMenu`: `ShortcutsModule(...).makeMenuItems().map(\.title) == ["Show Shortcuts…", "Check a Shortcut…"]` and descriptor id `"shortcuts"`.
- [ ] **Step 2: Run** — fails.
- [ ] **Step 3: Implement** the module (start: register window shortcut handler and app-launch observer that calls `store.capture(app:)` after 3 s when enabled and trusted; stop: undo both and close the window), the window per spec (sidebar sections, counts, searchable list, row badges, footer limit text, toolbar Rescan with progress), the check page per spec (recorder via local key-down monitor while focused, builder with modifier toggles and `KeyNames.pickerKeys` picker, verdict banner, owner lists, alternatives), the settings page per spec. Kick `store.refresh(captureMenus: true)` when the window opens.
- [ ] **Step 4: Run** `./scripts/test.sh` — all pass; `./scripts/build-app.sh` — succeeds.
- [ ] **Step 5: Manual check** — install, open window, confirm the two known clashes appear under Conflicts and the checker verdicts for ⌃⌥N (taken), ⌥Space (taken), ⌘C (standard), ⌃⌥⌘J (free).
- [ ] **Step 6: Commit** `feat(shortcuts): Shortcuts window, checker, settings`.
