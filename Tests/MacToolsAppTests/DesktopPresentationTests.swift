import AppKit
import MacToolsCore
import XCTest
@testable import MacTools

@MainActor
final class DesktopPresentationTests: XCTestCase {
    func test_OverviewNotificationsAreDistinctAndUnknownNamesAreRejected() {
        XCTAssertEqual(DesktopOverviewState(notification: "AXExposeShowDesktop"), .desktop)
        XCTAssertEqual(DesktopOverviewState(notification: "AXExposeShowAllWindows"), .allWindows)
        XCTAssertEqual(DesktopOverviewState(notification: "AXExposeShowFrontWindows"), .applicationWindows)
        XCTAssertEqual(DesktopOverviewState(notification: "AXExposeExit"), .inactive)
        XCTAssertNil(DesktopOverviewState(notification: "AXWindowCreated"))
    }

    func test_OnlySynchronizedModesPinAndOverviewModesHide() {
        for mode in NoteWorkspaceMode.allCases {
            for state in [DesktopOverviewState.unavailable, .unknown] {
                let flags = state.collectionBehavior(for: mode)
                XCTAssertTrue(flags.contains(.transient))
                XCTAssertFalse(flags.contains(.stationary))
                XCTAssertFalse(state.hidesNotes)
            }
            for state in [DesktopOverviewState.inactive, .desktop, .allWindows, .applicationWindows] {
                let flags = state.collectionBehavior(for: mode)
                XCTAssertTrue(flags.contains(.stationary))
                XCTAssertFalse(flags.contains(.transient))
                XCTAssertFalse(flags.contains(.managed))
                XCTAssertEqual(flags.contains(.canJoinAllSpaces), mode == .allWorkspaces)
                XCTAssertTrue(flags.contains(.fullScreenNone))
                XCTAssertEqual(state.hidesNotes, state == .allWindows || state == .applicationWindows)
            }
        }
    }

    func test_TransitionsKeepWindowAndFrameAndRestoreInputOnExitOrFailure() throws {
        _ = NSApplication.shared
        let suite = "DesktopPresentationTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = WorkspaceSettings(defaults: defaults)
        let presentation = DesktopPresentation()
        let frame = CGRect(x: 120, y: 140, width: 260, height: 200)
        let controller = StickyNoteWindowController(
            note: StickyNoteRecord(text: "Keep this text", frame: frame), frame: frame,
            focusInitially: false, workspaceSettings: settings, desktopPresentation: presentation,
            onTextChanged: { _, _ in XCTFail("Mode changes must not edit text") },
            onPaletteChanged: { _, _ in XCTFail("Mode changes must not edit colors") },
            onFrameChanged: { _, _, _ in XCTFail("Mode changes must not save transient geometry") },
            onDelete: { _ in XCTFail("Mode changes must not delete notes") })
        defer { controller.hide() }
        let window = try XCTUnwrap(controller.window)
        for mode in NoteWorkspaceMode.allCases {
            settings.setMode(mode)
            for state in [DesktopOverviewState.unknown, .inactive, .desktop, .allWindows,
                          .desktop, .applicationWindows, .inactive, .allWindows, .unavailable] {
                presentation.update(state)
                XCTAssertTrue(controller.window === window)
                XCTAssertEqual(window.frame, frame)
                XCTAssertEqual(window.level.rawValue, Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
                XCTAssertEqual(window.alphaValue, state.hidesNotes ? 0 : 1)
                XCTAssertEqual(window.ignoresMouseEvents, state.hidesNotes)
                XCTAssertEqual(window.canBecomeKey, !state.hidesNotes)
                XCTAssertEqual(window.collectionBehavior.contains(.transient), !state.canPin)
                XCTAssertEqual(window.collectionBehavior.contains(.canJoinAllSpaces), mode == .allWorkspaces)
            }
        }
        controller.flushTextChange()
    }

    func test_StoppingAnUnstartedMonitorIsSafeAndRestoresFallback() {
        let presentation = DesktopPresentation()
        let monitor = DockOverviewMonitor(presentation: presentation)
        presentation.update(.allWindows)
        monitor.stop()
        monitor.stop()
        XCTAssertEqual(presentation.state, .unavailable)
    }

    func test_RepositoryCoordinatorConnectsEveryRestoredNoteToPresentation() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = StickyNoteRepository(storageURL: root.appendingPathComponent("notes.json"))
        let visible = try XCTUnwrap(NSScreen.main).visibleFrame
        let frame = CGRect(x: visible.minX + 40, y: visible.minY + 40, width: 260, height: 200)
        let first = repository.create(text: "First saved note", frame: frame)
        let second = repository.create(text: "Second saved note", frame: frame.offsetBy(dx: 280, dy: 0))
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        let presentation = DesktopPresentation()
        let coordinator = StickyWindowCoordinator(repository: repository, desktopPresentation: presentation)
        coordinator.restoreActiveNotes()
        let windows = NSApp.windows.filter {
            !before.contains(ObjectIdentifier($0)) && $0.windowController is StickyNoteWindowController
        }
        defer { windows.forEach { $0.orderOut(nil) } }
        XCTAssertEqual(windows.count, 2)
        for state in [DesktopOverviewState.inactive, .desktop, .allWindows, .inactive, .unavailable] {
            presentation.update(state)
            for window in windows {
                XCTAssertEqual(window.alphaValue, state.hidesNotes ? 0 : 1)
                XCTAssertEqual(window.ignoresMouseEvents, state.hidesNotes)
                XCTAssertEqual(window.collectionBehavior.contains(.stationary), state.canPin)
            }
        }
        coordinator.flushPendingChanges()
        let reloaded = StickyNoteRepository(storageURL: root.appendingPathComponent("notes.json"))
        XCTAssertEqual(reloaded.note(id: first.id)?.text, "First saved note")
        XCTAssertEqual(reloaded.note(id: second.id)?.text, "Second saved note")
        XCTAssertEqual(reloaded.activeNotes.count, 2)
    }
}
