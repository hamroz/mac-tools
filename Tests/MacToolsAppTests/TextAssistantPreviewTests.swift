import AppKit
import XCTest
@testable import MacTools

@MainActor
final class TextAssistantPreviewTests: XCTestCase {
    func test_PreviewTakesTheKeyboardStreamsAndAnswersOnce() async throws {
        _ = NSApplication.shared
        let preview = TextAssistantPreview()
        preview.begin(title: "Improve · My style", canReplace: true)
        let panel = try XCTUnwrap(preview.panel)
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(panel.frame.width, 520, accuracy: 1)
        let shortHeight = panel.frame.height

        preview.update("So basically, we were thinking that the launch could possibly happen next week if design finishes the screens")
        XCTAssertEqual(preview.state.phase, .working)
        let decision = Task { await preview.finish("So basically, we were thinking that the launch could possibly happen next week if design finishes the screens and nobody finds any major bugs during testing. What do you think about that?") }
        await Task.yield()
        XCTAssertEqual(preview.state.phase, .ready)
        XCTAssertGreaterThanOrEqual(panel.frame.height, shortHeight)
        try snapshot(panel, "preview")

        decision.cancel()
        let answer = await decision.value
        XCTAssertEqual(answer, .cancel, "A newer run cancels a pending preview")
        preview.dismiss()
        XCTAssertFalse(panel.isVisible)
    }

    func test_ReadOnlyPreviewOffersOnlyCopy() throws {
        _ = NSApplication.shared
        let preview = TextAssistantPreview()
        defer { preview.dismiss() }
        preview.begin(title: "Translate · My style", canReplace: false)
        XCTAssertFalse(preview.state.canReplace)
        preview.fail("The model provider is rate limiting requests. Try again in a moment.")
        XCTAssertEqual(preview.state.phase, .failed("The model provider is rate limiting requests. Try again in a moment."))
        try snapshot(XCTUnwrap(preview.panel), "preview-failed")
    }

    /// Set SNAPSHOT_DIR to look at the rendered panel.
    private func snapshot(_ panel: NSPanel, _ name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"], let view = panel.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appending(path: "\(name).png"))
    }
}
