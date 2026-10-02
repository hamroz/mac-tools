import XCTest
@testable import MacToolsCore

final class KeyComboTests: XCTestCase {
    func test_carbonAndCocoaModifiersMatch() {
        XCTAssertEqual(ShortcutModifiers(carbon: 2048), [.option])
        XCTAssertEqual(ShortcutModifiers(carbon: 256 | 512), [.command, .shift])
        XCTAssertEqual(ShortcutModifiers(carbon: 4096), [.control])
        XCTAssertEqual(ShortcutModifiers(cocoa: 786432), [.control, .option])
        XCTAssertEqual(ShortcutModifiers(cocoa: 1179648), [.command, .shift])
        XCTAssertEqual(ShortcutModifiers(cocoa: 8650752), [.control, .function])
    }

    func test_axMenuModifiers() {
        XCTAssertEqual(ShortcutModifiers(axMenu: 0), [.command])
        XCTAssertEqual(ShortcutModifiers(axMenu: 1), [.command, .shift])
        XCTAssertEqual(ShortcutModifiers(axMenu: 2), [.command, .option])
        XCTAssertEqual(ShortcutModifiers(axMenu: 8), [])
        XCTAssertEqual(ShortcutModifiers(axMenu: 12), [.control])
        // Bit 16 is fn/Globe: Finder reports Emoji & Symbols (fn E) as 24 and Fill (fn⌃F) as 28.
        XCTAssertEqual(ShortcutModifiers(axMenu: 24), [.function])
        XCTAssertEqual(ShortcutModifiers(axMenu: 28), [.control, .function])
    }

    func test_displayString() {
        XCTAssertEqual(KeyCombo(keyCode: 45, modifiers: [.control, .option]).displayString, "⌃⌥N")
        XCTAssertEqual(KeyCombo(keyCode: 49, modifiers: [.option]).displayString, "⌥Space")
        XCTAssertEqual(KeyCombo(keyCode: 123, modifiers: [.control]).displayString, "⌃←")
        XCTAssertEqual(KeyCombo(keyCode: 12, modifiers: [.function]).displayString, "fnQ")
        XCTAssertEqual(KeyCombo(keyCode: 20, modifiers: [.command, .shift, .control]).displayString, "⌃⇧⌘3")
    }

    func test_implicitFunctionFlagIsDropped() {
        // Cocoa reports arrows and F-keys with the function flag; Carbon sources don't.
        XCTAssertEqual(KeyCombo(keyCode: 126, modifiers: [.control, .function]), KeyCombo(keyCode: 126, modifiers: [.control]))
        XCTAssertEqual(KeyCombo(keyCode: 122, modifiers: [.control, .function]).displayString, "⌃F1")
        XCTAssertEqual(KeyCombo(keyCode: 12, modifiers: [.function]).modifiers, [.function])
    }

    func test_searchTextHasWords() {
        let text = KeyCombo(keyCode: 49, modifiers: [.option]).searchText
        XCTAssertTrue(text.contains("opt"))
        XCTAssertTrue(text.contains("space"))
        XCTAssertTrue(text.contains("⌥Space"))
    }

    func test_userKeyEquivalent() {
        XCTAssertEqual(KeyCombo(userKeyEquivalent: "@$k"), KeyCombo(keyCode: 40, modifiers: [.command, .shift]))
        XCTAssertEqual(KeyCombo(userKeyEquivalent: "^~\u{F702}"), KeyCombo(keyCode: 123, modifiers: [.control, .option]))
        XCTAssertNil(KeyCombo(userKeyEquivalent: ""))
        XCTAssertNil(KeyCombo(userKeyEquivalent: "@"))
    }

    func test_characterLookup() {
        XCTAssertEqual(KeyNames.keyCode(forCharacter: "s"), 1)
        XCTAssertEqual(KeyNames.keyCode(forCharacter: "S"), 1)
        XCTAssertEqual(KeyNames.keyCode(forCharacter: ","), 43)
        XCTAssertNil(KeyNames.keyCode(forCharacter: "€"))
    }

    func test_menuGlyph() {
        XCTAssertEqual(KeyNames.keyCode(forMenuGlyph: 100), 123)
        XCTAssertEqual(KeyNames.keyCode(forMenuGlyph: 0x6F), 122)
        XCTAssertNil(KeyNames.keyCode(forMenuGlyph: 9999))
    }

    func test_combosSortAndRoundTrip() throws {
        let combo = KeyCombo(keyCode: 45, modifiers: [.control, .option])
        let data = try JSONEncoder().encode(combo)
        XCTAssertEqual(try JSONDecoder().decode(KeyCombo.self, from: data), combo)
        XCTAssertTrue(KeyNames.isFunctionKey(96))
        XCTAssertFalse(KeyNames.isFunctionKey(45))
        XCTAssertTrue(KeyNames.pickerKeys.contains(45))
    }
}
