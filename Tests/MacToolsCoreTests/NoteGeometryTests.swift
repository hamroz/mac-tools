import CoreGraphics
import XCTest
@testable import MacToolsCore

final class NoteGeometryTests: XCTestCase {
    func test_DisconnectedDisplayFallsBackToPrimaryAndClampsFrame() throws {
        let primary = NoteDisplay(id: 1, visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let other = NoteDisplay(id: 2, visibleFrame: CGRect(x: 800, y: 0, width: 800, height: 600))
        let frame = CGRect(x: 1200, y: 100, width: 260, height: 200)
        let before = try XCTUnwrap(NoteGeometry.placement(frame: frame, displayID: 2, displays: [primary, other]))
        XCTAssertEqual(before.frame, frame)
        XCTAssertEqual(before.displayID, 2)
        let after = try XCTUnwrap(NoteGeometry.placement(frame: frame, displayID: 2, displays: [primary]))
        XCTAssertEqual(after.displayID, 1)
        XCTAssertTrue(primary.visibleFrame.contains(after.frame))
    }

    func test_ResolutionChangeClampsAndNoDisplaysDefersRestoration() throws {
        let display = NoteDisplay(id: 1, visibleFrame: CGRect(x: -800, y: 25, width: 800, height: 550))
        let frame = CGRect(x: -80, y: 700, width: 260, height: 200)
        let placement = try XCTUnwrap(NoteGeometry.placement(frame: frame, displayID: 1, displays: [display]))
        XCTAssertEqual(placement.frame, CGRect(x: -260, y: 375, width: 260, height: 200))
        XCTAssertNil(NoteGeometry.placement(frame: frame, displayID: 1, displays: []))
    }

    func test_clampsSizeAndPositionInsideVisibleFrame() {
        let visible = CGRect(x: 100, y: 50, width: 900, height: 700)
        let result = NoteGeometry.clamped(
            CGRect(x: -500, y: 900, width: 900, height: 50),
            to: visible
        )

        XCTAssertEqual(result, CGRect(x: 100, y: 630, width: 520, height: 120))
        XCTAssertTrue(visible.contains(result))
    }

    func test_createsDefaultFrameNearPointerAndClampsAtEdges() {
        let visible = CGRect(x: 0, y: 0, width: 800, height: 600)
        let centered = NoteGeometry.frame(near: CGPoint(x: 400, y: 300), in: visible)
        XCTAssertEqual(centered, CGRect(x: 270, y: 200, width: 260, height: 200))

        let atCorner = NoteGeometry.frame(near: CGPoint(x: 795, y: 595), in: visible)
        XCTAssertEqual(atCorner.maxX, visible.maxX)
        XCTAssertEqual(atCorner.maxY, visible.maxY)
    }

    func test_handlesVisibleFramesSmallerThanMaximumNoteSize() {
        let visible = CGRect(x: 10, y: 20, width: 240, height: 160)
        let result = NoteGeometry.clamped(
            CGRect(x: 50, y: 50, width: 500, height: 500),
            to: visible
        )
        XCTAssertEqual(result, visible)
    }
}
