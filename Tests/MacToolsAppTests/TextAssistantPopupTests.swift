import AppKit
import KeyboardShortcuts
import XCTest
import MacToolsCore
@testable import MacTools

@MainActor
final class TextAssistantPopupTests: XCTestCase {
    private let config = TextAssistantConfig.defaults

    private func model(mode: String = "improve", tone: String = "my-style") -> TextAssistantPopupModel {
        let model = TextAssistantPopupModel()
        model.load(config: config, modeID: mode, toneID: tone)
        model.setSelection("helo")
        return model
    }

    func test_ArrowsChooseInTheFocusedListAndReturnRuns() {
        let popup = model()
        XCTAssertEqual(popup.column, .mode)
        XCTAssertEqual(popup.handle(.down), .handled)
        XCTAssertEqual(popup.handle(.down), .handled)
        XCTAssertEqual(popup.handle(.right), .handled)
        XCTAssertEqual(popup.handle(.down), .handled)
        XCTAssertEqual(popup.handle(.enter), .run(modeID: "translate", toneID: "original"))
    }

    func test_SelectionStopsAtTheEndsAndTabSwitchesLists() {
        let popup = model()
        _ = popup.handle(.up)
        XCTAssertEqual(popup.modeIndex, 0)
        for _ in 0..<10 { _ = popup.handle(.down) }
        XCTAssertEqual(popup.modeIndex, config.modes.count - 1)
        _ = popup.handle(.tab)
        XCTAssertEqual(popup.column, .tone)
        _ = popup.handle(.tab)
        XCTAssertEqual(popup.column, .mode)
        _ = popup.handle(.right)
        _ = popup.handle(.backTab)
        XCTAssertEqual(popup.column, .mode)
    }

    func test_NumbersAndLettersJumpToItems() {
        let popup = model()
        XCTAssertEqual(popup.handle(.character("3")), .handled)
        XCTAssertEqual(popup.currentChoice?.modeID, "translate")
        _ = popup.handle(.right)
        XCTAssertEqual(popup.handle(.character("f")), .handled)
        XCTAssertEqual(popup.currentChoice?.toneID, "formal")
        _ = popup.handle(.character("f"))
        XCTAssertEqual(popup.currentChoice?.toneID, "friendly", "The same letter moves to the next match")
        XCTAssertEqual(popup.handle(.character("z")), .ignored)
        XCTAssertEqual(popup.handle(.character("9")), .ignored, "Only 7 tones")
    }

    func test_ReturnWaitsForTheSelectionAndEscapeCancels() {
        let popup = TextAssistantPopupModel()
        popup.load(config: config, modeID: "fix", toneID: "formal")
        XCTAssertEqual(popup.currentChoice?.modeID, "fix")
        XCTAssertEqual(popup.handle(.enter), .handled, "Nothing runs before the selection is read")
        popup.setSelection("text")
        XCTAssertEqual(popup.handle(.enter), .run(modeID: "fix", toneID: "formal"))
        XCTAssertEqual(popup.handle(.escape), .cancel)
    }

    func test_PopupStartsWithLastModeAndMyStyleByDefault() throws {
        let suite = "PopupStart-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = TextAssistantSettings(defaults: defaults)
        XCTAssertTrue(settings.popupEnabled)
        XCTAssertTrue(settings.quickActionsEnabled)
        XCTAssertNil(KeyboardShortcuts.Name.textAssistantPopup.defaultShortcut, "No default shortcut")
        XCTAssertTrue(settings.popupStart(in: config) == ("improve", "my-style"))

        settings.rememberPopupChoice(modeID: "translate", toneID: "casual")
        XCTAssertTrue(settings.popupStart(in: config) == ("translate", "my-style"), "Mode: last used; tone: My style")
        settings.popupToneID = ""
        XCTAssertTrue(TextAssistantSettings(defaults: defaults).popupStart(in: config) == ("translate", "casual"))
        settings.popupModeID = "shorten"
        XCTAssertTrue(settings.popupStart(in: config) == ("shorten", "casual"))
        settings.popupModeID = "deleted-mode"
        XCTAssertTrue(settings.popupStart(in: config) == ("improve", "casual"), "Falls back to something that exists")
    }

    func test_PanelTakesTheKeyboardOnlyAfterTheSelectionIsRead() throws {
        _ = NSApplication.shared
        let popup = TextAssistantPopup()
        popup.show(config: config, modeID: "improve", toneID: "my-style")
        defer { popup.close() }
        let panel = try XCTUnwrap(popup.panel)
        XCTAssertTrue(panel.isVisible)
        XCTAssertFalse(panel.isKeyWindow, "⌘C must still reach the app being edited")
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertGreaterThan(panel.frame.height, 200)
        XCTAssertEqual(panel.frame.width, 480, accuracy: 1)
        popup.present(selection: "Some selected text")
        XCTAssertEqual(popup.model.selectionText, "Some selected text")
        try snapshot(panel)
    }

    /// Set SNAPSHOT_DIR to look at the rendered popup.
    private func snapshot(_ panel: NSPanel) throws {
        guard let directory = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"], let view = panel.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appending(path: "popup.png"))
    }
}
