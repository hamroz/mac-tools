import XCTest
@testable import MacToolsCore

final class ShortcutCheckerTests: XCTestCase {
    private let chatGPT = ShortcutSource.app(bundleID: "com.openai.chat", name: "ChatGPT")
    private let superwhisper = ShortcutSource.app(bundleID: "com.superduper.superwhisper", name: "Superwhisper")
    private let rectangle = ShortcutSource.app(bundleID: "com.knollsoft.Rectangle", name: "Rectangle")
    private let cursor = ShortcutSource.app(bundleID: "com.todesktop.cursor", name: "Cursor")

    private let ctrlOptN = KeyCombo(keyCode: 45, modifiers: [.control, .option])
    private let optSpace = KeyCombo(keyCode: 49, modifiers: [.option])
    private let cmdS = KeyCombo(keyCode: 1, modifiers: [.command])

    private var catalog: ShortcutCatalog {
        let chatSave = ShortcutEntry(combo: cmdS, action: "Toggle sidebar", source: chatGPT, scope: .global, isProbablyInApp: true)
        return ShortcutCatalog(entries: [
            ShortcutEntry(combo: ctrlOptN, action: "New Note", detail: "Desktop Stickies", source: .macTools, scope: .global),
            ShortcutEntry(combo: ctrlOptN, action: "Reflow Todo", source: rectangle, scope: .global),
            ShortcutEntry(combo: optSpace, action: "Toggle launcher", source: chatGPT, scope: .global),
            ShortcutEntry(combo: optSpace, action: "Toggle recording", source: superwhisper, scope: .global, isSourceRunning: false),
            ShortcutEntry(combo: KeyCombo(keyCode: 8, modifiers: [.command]), action: "Copy", detail: "Edit", source: .standard, scope: .inApp),
            ShortcutEntry(combo: cmdS, action: "Save", detail: "File", source: cursor, scope: .inApp),
            ShortcutEntry(combo: KeyCombo(keyCode: 49, modifiers: [.control]), action: "Select the previous input source", detail: "Input Sources", source: .macOS, scope: .global, isEnabled: false),
            chatSave,
            chatSave,
        ])
    }

    func test_realClashesDetected() {
        XCTAssertEqual(Set(catalog.conflicts.keys), [ctrlOptN, optSpace])
        XCTAssertEqual(catalog.conflicts[ctrlOptN]?.count, 2)
        let note = catalog.globalEntries.first { $0.action == "New Note" }!
        XCTAssertTrue(catalog.isConflicted(note))
    }

    func test_duplicateEntriesAreNotAClash() {
        XCTAssertEqual(catalog.entries.filter { $0.action == "Toggle sidebar" }.count, 1)
        let same = ShortcutEntry(combo: optSpace, action: "Toggle launcher", source: chatGPT, scope: .global)
        let other = ShortcutEntry(combo: optSpace, action: "Toggle launcher", detail: "Settings", source: chatGPT, scope: .global)
        XCTAssertTrue(ShortcutCatalog(entries: [same, other]).conflicts.isEmpty)
    }

    func test_scopesSplit() {
        XCTAssertTrue(catalog.globalEntries.allSatisfy { $0.scope == .global })
        XCTAssertTrue(catalog.inAppEntries.allSatisfy { $0.scope == .inApp })
        XCTAssertEqual(catalog.inAppEntries.count, 2)
    }

    func test_takenGlobally() {
        let result = ShortcutChecker.check(ctrlOptN, in: catalog)
        XCTAssertEqual(result.verdict, .takenGlobally)
        XCTAssertEqual(Set(result.globalOwners.map(\.action)), ["New Note", "Reflow Todo"])
    }

    func test_appNotRunningStillTaken() {
        XCTAssertEqual(ShortcutChecker.check(optSpace, in: catalog).globalOwners.count, 2)
    }

    func test_standard() {
        let result = ShortcutChecker.check(KeyCombo(keyCode: 8, modifiers: [.command]), in: catalog)
        XCTAssertEqual(result.verdict, .standard)
        XCTAssertEqual(result.standardMatches.map(\.action), ["Copy"])
    }

    func test_usedInApps() {
        let result = ShortcutChecker.check(cmdS, in: catalog)
        XCTAssertEqual(result.verdict, .usedInApps)
        XCTAssertEqual(result.inAppMatches.map(\.source.name), ["Cursor"])
        XCTAssertEqual(result.inactiveMatches.map(\.action), ["Toggle sidebar"])
    }

    func test_notUsable() {
        XCTAssertEqual(ShortcutChecker.check(KeyCombo(keyCode: 38, modifiers: []), in: catalog).verdict, .notUsable("Needs at least one modifier key"))
        XCTAssertEqual(ShortcutChecker.check(KeyCombo(keyCode: 38, modifiers: [.shift]), in: catalog).verdict, .notUsable("Shift alone types a character"))
        XCTAssertEqual(ShortcutChecker.check(KeyCombo(keyCode: 38, modifiers: [.function]), in: catalog).verdict, .notUsable("Needs at least one modifier key"))
    }

    func test_free() {
        XCTAssertEqual(ShortcutChecker.check(KeyCombo(keyCode: 96, modifiers: []), in: catalog).verdict, .free)
        XCTAssertEqual(ShortcutChecker.check(KeyCombo(keyCode: 38, modifiers: [.control, .option, .command]), in: catalog).verdict, .free)
        let offMatch = ShortcutChecker.check(KeyCombo(keyCode: 49, modifiers: [.control]), in: catalog)
        XCTAssertEqual(offMatch.verdict, .free)
        XCTAssertEqual(offMatch.inactiveMatches.count, 1)
    }

    func test_alternativesFreeFirst() {
        let alternatives = ShortcutChecker.alternatives(for: ctrlOptN, in: catalog)
        XCTAssertEqual(alternatives.count, 7)
        XCTAssertFalse(alternatives.contains { $0.combo == ctrlOptN })
        XCTAssertEqual(alternatives.first?.verdict, .free)
        XCTAssertTrue(alternatives.allSatisfy { $0.combo.keyCode == 45 })
    }

    func test_search() {
        let all = catalog.entries
        XCTAssertEqual(Set(catalog.entries(matching: "opt space", in: all).map(\.action)), ["Toggle launcher", "Toggle recording"])
        XCTAssertEqual(catalog.entries(matching: "reflow", in: all).map(\.source.name), ["Rectangle"])
        XCTAssertEqual(catalog.entries(matching: "⌃⌥N", in: all).count, 2)
        XCTAssertEqual(catalog.entries(matching: "  ", in: all).count, all.count)
    }
}
