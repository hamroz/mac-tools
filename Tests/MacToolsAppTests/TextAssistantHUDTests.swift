import AppKit
import XCTest
@testable import MacTools

@MainActor
final class TextAssistantHUDTests: XCTestCase {
    func test_BubbleIsSizedToItsMessageFromTheFirstShow() throws {
        _ = NSApplication.shared
        let hud = TextAssistantHUD()
        defer { hud.hide() }
        let message = "Add your OpenRouter API key in Mac Tools Settings → Text Assistant."

        hud.show(.failure(message))
        let panel = try XCTUnwrap(hud.panel)
        XCTAssertTrue(panel.isVisible)
        XCTAssertGreaterThan(panel.frame.width, 240, "The whole message must be readable")
        XCTAssertGreaterThan(panel.frame.height, 60, "Room for the message and its buttons")
        XCTAssertFalse(panel.ignoresMouseEvents, "Failures offer buttons")
        try snapshot(panel, named: "failure")

        hud.show(.working("Improving…"))
        XCTAssertLessThan(panel.frame.height, 60)
        XCTAssertTrue(panel.ignoresMouseEvents, "Progress never blocks clicks")
        XCTAssertFalse(panel.canBecomeKey, "The edited app keeps the keyboard")
        try snapshot(panel, named: "working")
    }

    /// Set HUD_SNAPSHOT_DIR to look at the rendered bubble.
    private func snapshot(_ panel: NSPanel, named name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["HUD_SNAPSHOT_DIR"],
              let view = panel.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: directory).appending(path: "hud-\(name).png"))
    }
}
