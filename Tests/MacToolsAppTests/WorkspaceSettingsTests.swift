import AppKit
import XCTest
import MacToolsCore
@testable import MacTools

@MainActor
final class WorkspaceSettingsTests: XCTestCase {
    func test_DefaultIsAllWorkspacesAndChoiceSurvivesRelaunch() throws {
        let suite = "MacToolsWorkspaceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = WorkspaceSettings(defaults: defaults)
        XCTAssertEqual(settings.mode, .allWorkspaces)
        settings.setMode(.individualWorkspaces)
        XCTAssertEqual(WorkspaceSettings(defaults: defaults).mode, .individualWorkspaces)
        settings.setMode(.allWorkspaces)
        XCTAssertEqual(WorkspaceSettings(defaults: defaults).mode, .allWorkspaces)
    }

    func test_BothModesHideInMissionControlAndExcludeFullScreen() {
        for mode in NoteWorkspaceMode.allCases {
            let behavior = mode.collectionBehavior
            XCTAssertTrue(behavior.contains(.transient))
            XCTAssertTrue(behavior.contains(.fullScreenNone))
            XCTAssertTrue(behavior.contains(.ignoresCycle))
            XCTAssertFalse(behavior.contains(.stationary))
            XCTAssertFalse(behavior.contains(.managed))
            XCTAssertFalse(behavior.contains(.fullScreenAuxiliary))
            XCTAssertFalse(behavior.contains(.moveToActiveSpace))
            XCTAssertEqual(behavior.contains(.canJoinAllSpaces), mode == .allWorkspaces)
        }
    }

    func test_ChangingModeUpdatesExistingWindowsWithoutReplacingThem() throws {
        _ = NSApplication.shared
        let suite = "MacToolsWorkspaceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = WorkspaceSettings(defaults: defaults)
        let frame = CGRect(x: 120, y: 140, width: 260, height: 200)
        let note = StickyNoteRecord(text: "Unchanged note", frame: frame)
        var frameChanges = 0
        let controller = StickyNoteWindowController(
            note: note, frame: frame, focusInitially: false, workspaceSettings: settings,
            onTextChanged: { _, _ in XCTFail("Workspace changes must not edit text") },
            onPaletteChanged: { _, _ in XCTFail("Workspace changes must not edit colors") },
            onFrameChanged: { _, _, _ in frameChanges += 1 }, onDelete: { _ in XCTFail("Must not delete") }
        )
        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(window.collectionBehavior.contains(.canJoinAllSpaces))
        for mode in [NoteWorkspaceMode.individualWorkspaces, .allWorkspaces] {
            settings.setMode(mode)
            XCTAssertTrue(controller.window === window)
            XCTAssertEqual(window.collectionBehavior, mode.collectionBehavior)
            XCTAssertEqual(window.frame, frame)
        }
        XCTAssertEqual(frameChanges, 0)
        controller.hide()
    }
}
