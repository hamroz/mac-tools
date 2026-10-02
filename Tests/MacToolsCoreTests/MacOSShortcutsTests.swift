import XCTest
@testable import MacToolsCore

final class MacOSShortcutsTests: XCTestCase {
    private func entry(_ action: String, in entries: [ShortcutEntry]) -> ShortcutEntry? {
        entries.first { $0.action == action }
    }

    func test_defaultsAppearWhenPlistIsEmpty() throws {
        let entries = MacOSShortcuts.entries(symbolicHotKeys: [:])
        let screenshot = try XCTUnwrap(entry("Save picture of screen as a file", in: entries))
        XCTAssertEqual(screenshot.combo, KeyCombo(keyCode: 20, modifiers: [.command, .shift]))
        XCTAssertEqual(screenshot.detail, "Screenshots")
        XCTAssertTrue(screenshot.isEnabled)
        XCTAssertEqual(screenshot.scope, .global)
        XCTAssertEqual(screenshot.source, .macOS)
        let spotlight = try XCTUnwrap(entry("Show Spotlight search", in: entries))
        XCTAssertEqual(spotlight.combo, KeyCombo(keyCode: 49, modifiers: [.command]))
    }

    func test_overrideReplacesDefault() throws {
        let plist: [String: Any] = ["64": ["enabled": true, "value": ["parameters": [32, 49, 1572864], "type": "standard"]]]
        let spotlight = try XCTUnwrap(entry("Show Spotlight search", in: MacOSShortcuts.entries(symbolicHotKeys: plist)))
        XCTAssertEqual(spotlight.combo, KeyCombo(keyCode: 49, modifiers: [.command, .option]))
    }

    func test_disabledEntryKeptAsOff() throws {
        let plist: [String: Any] = ["64": ["enabled": false, "value": ["parameters": [32, 49, 1048576]]]]
        let spotlight = try XCTUnwrap(entry("Show Spotlight search", in: MacOSShortcuts.entries(symbolicHotKeys: plist)))
        XCTAssertFalse(spotlight.isEnabled)
    }

    func test_desktopSwitchingIsOffByDefault() throws {
        let desktop1 = try XCTUnwrap(entry("Switch to Desktop 1", in: MacOSShortcuts.entries(symbolicHotKeys: [:])))
        XCTAssertEqual(desktop1.combo, KeyCombo(keyCode: 18, modifiers: [.control]))
        XCTAssertFalse(desktop1.isEnabled)
    }

    func test_noKeyMeansNoEntry() {
        let plist: [String: Any] = ["160": ["enabled": true, "value": ["parameters": [65535, 65535, 0]]]]
        XCTAssertNil(entry("Show Launchpad", in: MacOSShortcuts.entries(symbolicHotKeys: plist)))
    }

    func test_clearedDefaultDisappears() {
        let plist: [String: Any] = ["64": ["enabled": true, "value": ["parameters": [65535, 65535, 0]]]]
        XCTAssertNil(entry("Show Spotlight search", in: MacOSShortcuts.entries(symbolicHotKeys: plist)))
    }

    func test_unknownIDWithComboAppears() throws {
        let plist: [String: Any] = ["999": ["enabled": true, "value": ["parameters": [97, 0, 1048576]]]]
        let unknown = try XCTUnwrap(entry("macOS shortcut #999", in: MacOSShortcuts.entries(symbolicHotKeys: plist)))
        XCTAssertEqual(unknown.combo, KeyCombo(keyCode: 0, modifiers: [.command]))
    }

    func test_slowMotionDuplicatesHidden() {
        let plist: [String: Any] = ["34": ["enabled": true, "value": ["parameters": [65535, 126, 8781824]]]]
        let entries = MacOSShortcuts.entries(symbolicHotKeys: plist)
        XCTAssertFalse(entries.contains { $0.action.contains("#34") })
        XCTAssertEqual(entries.filter { $0.action == "Mission Control" }.count, 1)
    }

    func test_malformedParametersSkipped() {
        let plist: [String: Any] = [
            "64": ["enabled": true, "value": ["parameters": ["x", "y", "z"]]],
            "998": "nonsense",
            "997": ["value": ["parameters": [97, 70000, 1048576]]],
        ]
        let entries = MacOSShortcuts.entries(symbolicHotKeys: plist)
        XCTAssertNotNil(entry("Show Spotlight search", in: entries), "falls back to the default")
        XCTAssertFalse(entries.contains { $0.action.hasPrefix("macOS shortcut #99") })
    }

    func test_fixedAndStandardLists() throws {
        let forceQuit = try XCTUnwrap(entry("Force Quit Applications", in: MacOSShortcuts.fixed))
        XCTAssertEqual(forceQuit.combo, KeyCombo(keyCode: 53, modifiers: [.command, .option]))
        XCTAssertEqual(forceQuit.scope, .global)
        let copy = try XCTUnwrap(entry("Copy", in: MacOSShortcuts.standard))
        XCTAssertEqual(copy.combo, KeyCombo(keyCode: 8, modifiers: [.command]))
        XCTAssertEqual(copy.scope, .inApp)
        XCTAssertEqual(copy.source, .standard)
    }
}
