import XCTest
@testable import MacToolsCore

final class PreferenceShortcutTests: XCTestCase {
    private func entry(_ action: String, in entries: [ShortcutEntry]) -> ShortcutEntry? {
        entries.first { $0.action == action }
    }

    // MARK: Rectangle

    func test_rectangleAlternateDefaults() throws {
        let entries = RectangleShortcuts.entries(preferences: ["alternateDefaultShortcuts": true], isRunning: true)
        XCTAssertEqual(try XCTUnwrap(entry("Left Half", in: entries)).combo, KeyCombo(keyCode: 123, modifiers: [.control, .option]))
        XCTAssertEqual(try XCTUnwrap(entry("Maximize", in: entries)).combo, KeyCombo(keyCode: 36, modifiers: [.control, .option]))
        let left = try XCTUnwrap(entry("Left Half", in: entries))
        XCTAssertEqual(left.source.id, RectangleShortcuts.bundleID)
        XCTAssertEqual(left.source.name, "Rectangle")
        XCTAssertEqual(left.scope, .global)
    }

    func test_rectangleOverrideAndCleared() throws {
        let preferences: [String: Any] = [
            "alternateDefaultShortcuts": true,
            "leftHalf": ["keyCode": 0, "modifierFlags": 1572864],
            "maximize": [String: Any](),
            "reflowTodo": ["keyCode": 45, "modifierFlags": 786432],
        ]
        let entries = RectangleShortcuts.entries(preferences: preferences, isRunning: false)
        XCTAssertEqual(try XCTUnwrap(entry("Left Half", in: entries)).combo, KeyCombo(keyCode: 0, modifiers: [.option, .command]))
        XCTAssertNil(entry("Maximize", in: entries))
        let reflow = try XCTUnwrap(entry("Reflow Todo", in: entries))
        XCTAssertEqual(reflow.combo, KeyCombo(keyCode: 45, modifiers: [.control, .option]))
        XCTAssertFalse(reflow.isSourceRunning)
    }

    func test_rectangleSpectacleDefaults() throws {
        let entries = RectangleShortcuts.entries(preferences: ["alternateDefaultShortcuts": false], isRunning: true)
        XCTAssertEqual(try XCTUnwrap(entry("Left Half", in: entries)).combo, KeyCombo(keyCode: 123, modifiers: [.option, .command]))
    }

    // MARK: Generic scan

    func test_keyboardShortcutsJSON() throws {
        let preferences: [String: Any] = ["KeyboardShortcuts_toggleLauncher": "{\"carbonModifiers\":2048,\"carbonKeyCode\":49}"]
        let entries = PreferenceShortcutScanner.entries(bundleID: "com.openai.chat", appName: "ChatGPT", preferences: preferences, isRunning: true)
        let launcher = try XCTUnwrap(entry("Toggle launcher", in: entries))
        XCTAssertEqual(launcher.combo, KeyCombo(keyCode: 49, modifiers: [.option]))
        XCTAssertEqual(launcher.scope, .global)
        XCTAssertFalse(launcher.isProbablyInApp)
        XCTAssertEqual(launcher.source, .app(bundleID: "com.openai.chat", name: "ChatGPT"))
    }

    func test_cocoaDicts() throws {
        let preferences: [String: Any] = [
            "startMenuShortcutHotKey": ["keyCode": 49, "modifiers": 262144],
            "settings": ["hotkeys": ["showPanel": ["keyCode": 35, "modifierFlags": 1572864]]],
            "carbonOne": ["carbonKeyCode": 45, "carbonModifiers": 4096 | 2048],
        ]
        let entries = PreferenceShortcutScanner.entries(bundleID: "com.example", appName: "Example", preferences: preferences, isRunning: true)
        XCTAssertEqual(try XCTUnwrap(entry("Start menu shortcut hot key", in: entries)).combo, KeyCombo(keyCode: 49, modifiers: [.control]))
        XCTAssertEqual(try XCTUnwrap(entry("Show panel", in: entries)).combo, KeyCombo(keyCode: 35, modifiers: [.option, .command]))
        XCTAssertEqual(try XCTUnwrap(entry("Carbon one", in: entries)).combo, KeyCombo(keyCode: 45, modifiers: [.control, .option]))
    }

    func test_probablyInApp() {
        XCTAssertTrue(PreferenceShortcutScanner.isProbablyInApp(KeyCombo(keyCode: 1, modifiers: [.command])))
        XCTAssertTrue(PreferenceShortcutScanner.isProbablyInApp(KeyCombo(keyCode: 40, modifiers: [.shift, .command])))
        XCTAssertTrue(PreferenceShortcutScanner.isProbablyInApp(KeyCombo(keyCode: 125, modifiers: [])))
        XCTAssertFalse(PreferenceShortcutScanner.isProbablyInApp(KeyCombo(keyCode: 49, modifiers: [.option])))
        XCTAssertFalse(PreferenceShortcutScanner.isProbablyInApp(KeyCombo(keyCode: 49, modifiers: [.command])))
        XCTAssertFalse(PreferenceShortcutScanner.isProbablyInApp(KeyCombo(keyCode: 96, modifiers: [.command])))
        XCTAssertFalse(PreferenceShortcutScanner.isProbablyInApp(KeyCombo(keyCode: 45, modifiers: [.control, .option])))
    }

    func test_humanize() {
        XCTAssertEqual(PreferenceShortcutScanner.humanize("toggleLauncher"), "Toggle launcher")
        XCTAssertEqual(PreferenceShortcutScanner.humanize("Paraphrasing_Open"), "Paraphrasing open")
        XCTAssertEqual(PreferenceShortcutScanner.humanize("OpenInEditorShortcut"), "Open in editor shortcut")
        XCTAssertEqual(PreferenceShortcutScanner.humanize("textAssistant.improve"), "Text assistant improve")
    }

    func test_malformedValuesSkipped() {
        let preferences: [String: Any] = [
            "a": ["keyCode": "x", "modifierFlags": 0],
            "b": ["keyCode": -1, "modifierFlags": 0],
            "c": ["keyCode": 70000, "modifierFlags": 0],
            "d": ["keyCode": 1, "modifierFlags": -5],
            "KeyboardShortcuts_bad": "{bad",
            "KeyboardShortcuts_wrongTypes": "{\"carbonModifiers\":\"x\",\"carbonKeyCode\":49}",
            "KeyboardShortcuts_data": Data([1, 2, 3]),
        ]
        XCTAssertEqual(PreferenceShortcutScanner.entries(bundleID: "x", appName: "X", preferences: preferences, isRunning: true), [])
    }

    func test_userKeyEquivalents() throws {
        let source = ShortcutSource.app(bundleID: "com.example", name: "Example")
        let entries = PreferenceShortcutScanner.userKeyEquivalents(["Export…": "@$e", "Broken": "@", "Bad": 5], source: source)
        XCTAssertEqual(entries.count, 1)
        let export = try XCTUnwrap(entry("Export…", in: entries))
        XCTAssertEqual(export.combo, KeyCombo(keyCode: 14, modifiers: [.shift, .command]))
        XCTAssertEqual(export.scope, .inApp)
        XCTAssertEqual(PreferenceShortcutScanner.userKeyEquivalents(nil, source: source), [])
    }
}
