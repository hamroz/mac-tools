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
                let flags = mode.collectionBehavior(pinned: state.canPin)
                XCTAssertTrue(flags.contains(.transient))
                XCTAssertFalse(flags.contains(.stationary))
                XCTAssertFalse(state.hidesNotes)
            }
            for state in [DesktopOverviewState.inactive, .desktop, .allWindows, .applicationWindows] {
                let flags = mode.collectionBehavior(pinned: state.canPin)
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

    func test_OverlaySignalPairsMissionControlWindowsButIgnoresShowDesktop() {
        var signal = DockOverviewWindowSignal()
        signal.reset(layer18: [], layer20: [1])

        // Show Desktop creates the layer-18 window alone: notes stay visible.
        XCTAssertFalse(signal.observe(layer18: [2], layer20: [1], tick: 1))
        XCTAssertFalse(signal.observe(layer18: [2], layer20: [1], tick: 2))
        // Closing Show Desktop must not leave a candidate behind.
        XCTAssertFalse(signal.observe(layer18: [], layer20: [1], tick: 3))
        XCTAssertFalse(signal.observe(layer18: [], layer20: [1, 9], tick: 4))

        // Mission Control adds a new full-screen layer-20 window: hide at once.
        XCTAssertTrue(signal.observe(layer18: [10], layer20: [1, 11], tick: 5))
        XCTAssertTrue(signal.observe(layer18: [10], layer20: [1, 11], tick: 6))
        // Hiding lasts until the layer-18 window is gone.
        XCTAssertFalse(signal.observe(layer18: [], layer20: [1], tick: 7))

        // A delayed companion still pairs within the window, but not later.
        XCTAssertFalse(signal.observe(layer18: [20], layer20: [], tick: 8))
        XCTAssertTrue(signal.observe(layer18: [20], layer20: [21], tick: 10))
        XCTAssertFalse(signal.observe(layer18: [], layer20: [], tick: 11))
        XCTAssertFalse(signal.observe(layer18: [30], layer20: [], tick: 12))
        XCTAssertFalse(signal.observe(layer18: [30], layer20: [31], tick: 20))
    }

    func test_OverlaySignalHidesForWindowManagerExposeShield() {
        var signal = DockOverviewWindowSignal()
        signal.reset(layer18: [], layer20: [1])

        // macOS 27: Show Desktop is a WindowManager layer-18 overlay, which the
        // probe does not collect, so the Dock's windows stay unchanged.
        XCTAssertFalse(signal.observe(layer18: [], layer20: [1], exposeShield: [], tick: 1))

        // Mission Control and App Exposé add a WindowManager layer-19 shield.
        XCTAssertTrue(signal.observe(layer18: [], layer20: [1], exposeShield: [5], tick: 2))
        XCTAssertTrue(signal.observe(layer18: [], layer20: [1], exposeShield: [5], tick: 3))
        XCTAssertFalse(signal.observe(layer18: [], layer20: [1], exposeShield: [], tick: 4))

        // A shield that outlives the legacy Dock pair keeps notes hidden.
        XCTAssertTrue(signal.observe(layer18: [10], layer20: [1, 11], exposeShield: [6], tick: 5))
        XCTAssertTrue(signal.observe(layer18: [], layer20: [1], exposeShield: [6], tick: 6))
        XCTAssertFalse(signal.observe(layer18: [], layer20: [1], exposeShield: [], tick: 7))
    }

    func test_OverlayHidesNotesBeforeDockNotificationAndRestoresOnExit() throws {
        _ = NSApplication.shared
        let suite = "DesktopPresentationTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = WorkspaceSettings(defaults: defaults)
        let presentation = DesktopPresentation()
        let frame = CGRect(x: 120, y: 140, width: 260, height: 200)
        let controller = StickyNoteWindowController(
            note: StickyNoteRecord(text: "Overlay", frame: frame), frame: frame,
            focusInitially: false, workspaceSettings: settings, desktopPresentation: presentation,
            onTextChanged: { _, _ in XCTFail("Overlay changes must not edit text") },
            onPaletteChanged: { _, _ in XCTFail("Overlay changes must not edit colors") },
            onFrameChanged: { _, _, _ in XCTFail("Overlay changes must not save transient geometry") },
            onDelete: { _ in XCTFail("Overlay changes must not delete notes") })
        defer { controller.hide() }
        let window = try XCTUnwrap(controller.window)

        presentation.update(.desktop)
        presentation.updateOverlay(hidesNotes: true)
        XCTAssertTrue(presentation.hidesNotes)
        XCTAssertEqual(window.alphaValue, 0)
        XCTAssertTrue(window.ignoresMouseEvents)
        XCTAssertFalse(window.canBecomeKey)
        XCTAssertTrue(window.collectionBehavior.contains(.stationary))

        presentation.updateOverlay(hidesNotes: false)
        XCTAssertFalse(presentation.hidesNotes)
        XCTAssertEqual(window.alphaValue, 1)
        XCTAssertFalse(window.ignoresMouseEvents)
        XCTAssertTrue(window.canBecomeKey)
        controller.flushTextChange()
    }

    func test_ProbeReadinessPinsNotesWithoutAccessibility() throws {
        _ = NSApplication.shared
        let suite = "DesktopPresentationTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = WorkspaceSettings(defaults: defaults)
        let presentation = DesktopPresentation()
        let frame = CGRect(x: 120, y: 140, width: 260, height: 200)
        let controller = StickyNoteWindowController(
            note: StickyNoteRecord(text: "Probe", frame: frame), frame: frame,
            focusInitially: false, workspaceSettings: settings, desktopPresentation: presentation,
            onTextChanged: { _, _ in XCTFail("Probe readiness must not edit text") },
            onPaletteChanged: { _, _ in XCTFail("Probe readiness must not edit colors") },
            onFrameChanged: { _, _, _ in XCTFail("Probe readiness must not save geometry") },
            onDelete: { _ in XCTFail("Probe readiness must not delete notes") })
        defer { controller.hide() }
        let window = try XCTUnwrap(controller.window)

        XCTAssertEqual(presentation.state, .unavailable)
        XCTAssertFalse(presentation.pinsNotes)
        XCTAssertTrue(window.collectionBehavior.contains(.transient))

        presentation.markProbeReady()
        XCTAssertTrue(presentation.pinsNotes)
        XCTAssertTrue(window.collectionBehavior.contains(.stationary))
        XCTAssertFalse(window.collectionBehavior.contains(.transient))
        XCTAssertEqual(window.alphaValue, 1)
        controller.flushTextChange()
    }
}
