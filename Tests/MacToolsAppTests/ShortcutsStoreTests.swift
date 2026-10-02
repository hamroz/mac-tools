import AppKit
import KeyboardShortcuts
import ApplicationServices
import XCTest
import MacToolsCore
@testable import MacTools

@MainActor
final class ShortcutsStoreTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Preferences"), withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func writePlist(_ name: String, _ value: [String: Any]) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
        try data.write(to: root.appendingPathComponent("Preferences/\(name).plist"))
    }

    private func makeStore(installed: [String: String] = [:], running: [ShortcutsStore.RunningApp] = []) -> ShortcutsStore {
        let note = ShortcutEntry(combo: KeyCombo(keyCode: 45, modifiers: [.control, .option]), action: "New Note", detail: "Desktop Stickies", source: .macTools, scope: .global)
        return ShortcutsStore(
            cache: MenuShortcutCacheStore(url: root.appendingPathComponent("cache.json")),
            preferencesDirectory: root.appendingPathComponent("Preferences"),
            appLocator: { bundleID in installed[bundleID].map { URL(fileURLWithPath: "/Applications/\($0).app") } },
            runningApplications: { running },
            macToolsShortcuts: { [note] }
        )
    }

    func test_refreshBuildsCatalogFromFixtureDirectory() async throws {
        try writePlist("com.example.fake", ["KeyboardShortcuts_ghost": "{\"carbonModifiers\":2048,\"carbonKeyCode\":5}"])
        try writePlist("com.example.app", ["KeyboardShortcuts_toggleLauncher": "{\"carbonModifiers\":2048,\"carbonKeyCode\":49}"])
        try writePlist("com.knollsoft.Rectangle", ["alternateDefaultShortcuts": true, "reflowTodo": ["keyCode": 45, "modifierFlags": 786432]])
        try writePlist("com.apple.symbolichotkeys", ["AppleSymbolicHotKeys": ["64": ["enabled": false, "value": ["parameters": [32, 49, 1048576]]]]])
        let store = makeStore(installed: ["com.example.app": "Example", RectangleShortcuts.bundleID: "Rectangle"])

        await store.refresh(captureMenus: false)

        let global = store.catalog.globalEntries
        XCTAssertFalse(global.contains { $0.action == "Ghost" }, "apps that aren't installed are ignored")
        let launcher = try XCTUnwrap(global.first { $0.action == "Toggle launcher" })
        XCTAssertEqual(launcher.source.name, "Example")
        XCTAssertTrue(global.contains { $0.action == "New Note" && $0.source == .macTools })
        XCTAssertFalse(try XCTUnwrap(global.first { $0.action == "Show Spotlight search" }).isEnabled)
        XCTAssertTrue(global.contains { $0.action == "Force Quit Applications" })
        XCTAssertTrue(store.catalog.inAppEntries.contains { $0.source == .standard && $0.action == "Copy" })
        XCTAssertEqual(store.catalog.conflicts[KeyCombo(keyCode: 45, modifiers: [.control, .option])]?.count, 2)
        XCTAssertNotNil(store.lastScan)
        XCTAssertFalse(store.isScanning)
    }

    func test_menuBarAppsCountAsRunning() async throws {
        // Rectangle is an LSUIElement (accessory) app: it has no Dock icon but its hotkeys are live.
        let rectangle = ShortcutsStore.RunningApp(pid: 1, bundleID: RectangleShortcuts.bundleID, name: "Rectangle", isRegular: false)
        let store = makeStore(installed: [RectangleShortcuts.bundleID: "Rectangle"], running: [rectangle])
        await store.refresh(captureMenus: false)
        let leftHalf = try XCTUnwrap(store.catalog.globalEntries.first { $0.action == "Left Half" })
        XCTAssertTrue(leftHalf.isSourceRunning)
    }

    func test_notLoadedUntilFirstScanFinishes() async {
        // The checker must not call anything "Free" against an empty catalog.
        let store = makeStore()
        XCTAssertFalse(store.hasLoaded)
        await store.refresh(captureMenus: false)
        XCTAssertTrue(store.hasLoaded)
    }

    func test_rectangleNeedsToBeInstalled() async {
        let store = makeStore()
        await store.refresh(captureMenus: false)
        XCTAssertFalse(store.catalog.entries.contains { $0.source.id == RectangleShortcuts.bundleID })
    }

    func test_cachedMenusShowAndForgetClearsThem() async throws {
        let cache = MenuShortcutCacheStore(url: root.appendingPathComponent("cache.json"))
        let captured = CapturedApp(bundleID: "com.example.app", name: "Example", capturedAt: Date(), items: [
            MenuShortcut(path: ["File"], title: "Export", combo: KeyCombo(keyCode: 14, modifiers: [.shift, .command]), isEnabled: true),
        ])
        try cache.save(["com.example.app": captured, "com.example.gone": CapturedApp(bundleID: "com.example.gone", name: "Gone", capturedAt: Date(), items: captured.items)])
        let store = makeStore(installed: ["com.example.app": "Example"])

        await store.refresh(captureMenus: false)
        XCTAssertTrue(store.catalog.inAppEntries.contains { $0.action == "Export" && $0.source.name == "Example" })
        XCTAssertEqual(Set(store.capturedApps.keys), ["com.example.app"], "uninstalled apps are dropped")

        store.forgetCapturedMenus()
        XCTAssertTrue(store.capturedApps.isEmpty)
        XCTAssertFalse(store.catalog.inAppEntries.contains { $0.action == "Export" })
        XCTAssertEqual(cache.load(), [:])
    }

    func test_readsFinderMenus() throws {
        try XCTSkipUnless(AXIsProcessTrusted(), "needs Accessibility")
        let finder = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first)
        let captured = try XCTUnwrap(MenuShortcutReader.capture(pid: finder.processIdentifier, bundleID: "com.apple.finder", name: "Finder"))
        let newFolder = try XCTUnwrap(captured.items.first { $0.title == "New Folder" })
        XCTAssertEqual(newFolder.combo, KeyCombo(keyCode: 45, modifiers: [.shift, .command]))
        XCTAssertEqual(newFolder.path, ["File"])
    }
}

@MainActor
final class ShortcutListGroupingTests: XCTestCase {
    private func entry(_ action: String, _ detail: String, key: UInt16, enabled: Bool = true, source: ShortcutSource = .macOS) -> ShortcutEntry {
        ShortcutEntry(combo: KeyCombo(keyCode: key, modifiers: [.control]), action: action, detail: detail, source: source, scope: .global, isEnabled: enabled)
    }

    func test_sourceGroupsOrderByAreaWithOffShortcutsLast() {
        let entries = [
            entry("Switch to Desktop 1", "Mission Control", key: 18, enabled: false),
            entry("Mission Control", "Mission Control", key: 126),
            entry("Save picture", "Screenshots", key: 20),
            entry("Zoom in", "Accessibility", key: 24),
        ]
        let groups = ShortcutListView.group(entries, by: .source)
        XCTAssertEqual(groups.map(\.title), ["macOS"])
        XCTAssertEqual(groups[0].entries.map(\.action), ["Zoom in", "Mission Control", "Save picture", "Switch to Desktop 1"])
    }

    func test_sourceGroupsPutMacOSAndMacToolsFirst() {
        let rectangle = ShortcutSource.app(bundleID: "r", name: "Rectangle")
        let groups = ShortcutListView.group([
            entry("Left Half", "Window management", key: 123, source: rectangle),
            entry("New Note", "Desktop Stickies", key: 45, source: .macTools),
            entry("Spotlight", "Spotlight", key: 49),
        ], by: .source)
        XCTAssertEqual(groups.map(\.title), ["macOS", "Mac Tools", "Rectangle"])
    }

    func test_detailGroupsSortByTitle() {
        let groups = ShortcutListView.group([entry("B", "View", key: 1), entry("A", "File", key: 2)], by: .detail)
        XCTAssertEqual(groups.map(\.title), ["File", "View"])
    }
}

@MainActor
final class ComboRecorderTests: XCTestCase {
    func test_recordingStopsWhenFocusLeaves() {
        for name in [NSApplication.didResignActiveNotification, NSWindow.didResignKeyNotification] {
            let recorder = ComboRecorder()
            var changes: [Bool] = []
            recorder.onRecordingChange = { changes.append($0) }
            recorder.start()
            XCTAssertTrue(recorder.isRecording)
            NotificationCenter.default.post(name: name, object: nil)
            XCTAssertFalse(recorder.isRecording, "\(name.rawValue) must end recording")
            XCTAssertEqual(changes, [true, false], "hotkeys are resumed exactly once")
        }
    }

    func test_resumeOnlyRestoresHotKeysOfToolsStillOn() {
        let names: [KeyboardShortcuts.Name] = [.textAssistantImprove, .shortcutsShowWindow]
        XCTAssertEqual(AppDelegate.namesToResume(names, enabledTools: ["shortcuts"]), [.shortcutsShowWindow])
        XCTAssertEqual(AppDelegate.namesToResume(names, enabledTools: ["text-assistant", "shortcuts"]), names)
        XCTAssertEqual(AppDelegate.namesToResume(names, enabledTools: []), [])
    }
}
