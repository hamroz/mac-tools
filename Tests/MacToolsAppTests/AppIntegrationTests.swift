import AppKit
import SwiftUI
import XCTest
import MacToolsCore
@testable import MacTools

@MainActor
final class AppIntegrationTests: XCTestCase {
    func test_MenuShortcutTracksSettingsWithoutRebuildingMenu() throws {
        let suite = "MacToolsShortcutTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let hotKeys = HotKeyManager(defaults: defaults)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repository = StickyNoteRepository(storageURL: root.appendingPathComponent("notes.json"))
        let module = DesktopStickiesModule(repository: repository, hotKeyManager: hotKeys)
        let item = try XCTUnwrap(module.makeMenuItems().first)
        for preset in HotKeyPreset.allCases {
            hotKeys.setPreset(preset)
            XCTAssertEqual(item.keyEquivalent, preset.keyEquivalent)
            XCTAssertEqual(item.keyEquivalentModifierMask, preset.appKitModifiers)
            XCTAssertEqual(HotKeyManager(defaults: defaults).preset, preset)
        }
    }

    func test_RegistryExposesEveryToolAndRunsLifecycle() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = FakeTool(id: "first")
        let second = FakeTool(id: "second")
        let registry = ToolRegistry(modules: [first, second], defaults: defaults)
        let menu = registry.makeMenu()
        XCTAssertEqual(menu.items.filter { !$0.isSeparatorItem }.map(\.title), ["first", "first command", "second", "second command"])
        registry.startAll()
        registry.stopAll()
        XCTAssertEqual(first.events, ["start", "stop"])
        XCTAssertEqual(second.events, ["start", "stop"])
    }

    func test_TurningToolOffStopsItHidesItsMenuAndPersists() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = FakeTool(id: "first")
        let second = FakeTool(id: "second")
        let registry = ToolRegistry(modules: [first, second], defaults: defaults)
        var changes = 0
        registry.onChange = { changes += 1 }
        registry.startAll()

        registry.setEnabled(false, for: "first")
        XCTAssertEqual(first.events, ["start", "stop"])
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(registry.makeMenu().items.filter { !$0.isSeparatorItem }.map(\.title), ["second", "second command"])

        registry.setEnabled(false, for: "first")
        XCTAssertEqual(changes, 1, "Repeating the current state must not restart or rebuild anything")

        let relaunched = ToolRegistry(modules: [FakeTool(id: "first"), FakeTool(id: "second")], defaults: defaults)
        XCTAssertFalse(relaunched.isEnabled("first"))
        XCTAssertTrue(relaunched.isEnabled("second"))

        registry.stopAll()
        XCTAssertEqual(first.events, ["start", "stop"], "A tool that is off must not be stopped twice")
        registry.setEnabled(true, for: "first")
        XCTAssertEqual(first.events, ["start", "stop"], "Tools do not start while the app is shutting down")
        XCTAssertTrue(registry.isEnabled("first"))
    }

    func test_ToolsCanOpenTheirOwnSettingsPage() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let tool = FakeTool(id: "tool")
        let registry = ToolRegistry(modules: [tool], defaults: defaults)
        var opened: [String] = []
        registry.onOpenSettings = { opened.append($0) }
        tool.openSettings?()
        XCTAssertEqual(opened, ["tool"])
    }

    func test_TurningStickiesOffClosesEveryNoteWindow() throws {
        _ = NSApplication.shared
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = StickyNoteRepository(storageURL: root.appendingPathComponent("notes.json"))
        _ = repository.create(frame: CGRect(x: 200, y: 200, width: 260, height: 200), displayID: nil)
        let coordinator = StickyWindowCoordinator(repository: repository, workspaceSettings: WorkspaceSettings(defaults: defaults))
        let noteWindows = { NSApp.windows.filter { $0.isVisible && $0.level.rawValue < NSWindow.Level.normal.rawValue } }

        coordinator.restoreActiveNotes()
        XCTAssertEqual(noteWindows().count, 1)
        coordinator.restoreActiveNotes()
        XCTAssertEqual(noteWindows().count, 1, "Turning the tool back on must not duplicate open notes")

        coordinator.closeAll()
        XCTAssertTrue(noteWindows().isEmpty)
        XCTAssertEqual(repository.activeNotes.count, 1, "Turning the tool off keeps its notes")
    }

    func test_ShortcutPresentationsAgreeAcrossAllPresets() {
        for preset in HotKeyPreset.allCases {
            XCTAssertEqual(preset.keyEquivalent, preset == .controlOptionS ? "s" : "n")
            XCTAssertEqual(preset.appKitModifiers.contains(.control), preset.modifiers.contains(.control))
            XCTAssertEqual(preset.appKitModifiers.contains(.option), preset.modifiers.contains(.option))
            XCTAssertEqual(preset.appKitModifiers.contains(.shift), preset.modifiers.contains(.shift))
            XCTAssertEqual(preset.appKitModifiers.contains(.command), preset.modifiers.contains(.command))
            XCTAssertEqual(preset.swiftUIModifiers.contains(.control), preset.modifiers.contains(.control))
            XCTAssertEqual(preset.swiftUIModifiers.contains(.option), preset.modifiers.contains(.option))
            XCTAssertEqual(preset.swiftUIModifiers.contains(.shift), preset.modifiers.contains(.shift))
            XCTAssertEqual(preset.swiftUIModifiers.contains(.command), preset.modifiers.contains(.command))
        }
    }

    func test_StickyWindowUsesDesktopLayerAndSupportedSpaceFlags() throws {
        _ = NSApplication.shared
        let frame = CGRect(x: 100, y: 100, width: 260, height: 200)
        let controller = StickyNoteWindowController(
            note: StickyNoteRecord(frame: frame), frame: frame, focusInitially: false,
            onTextChanged: { _, _ in }, onPaletteChanged: { _, _ in },
            onFrameChanged: { _, _, _ in }, onDelete: { _ in }
        )
        let window = try XCTUnwrap(controller.window)
        XCTAssertEqual(window.frame, frame)
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        let hit = content.hitTest(NSPoint(x: 35, y: content.bounds.height - 18))
        XCTAssertTrue(hit is DraggingView, "The header must hit the native drag handle, not the text editor or a decoration")
        XCTAssertTrue(hit?.acceptsFirstMouse(for: nil) == true)
        XCTAssertLessThan(window.level.rawValue, NSWindow.Level.normal.rawValue)
        XCTAssertEqual(window.level.rawValue, Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        XCTAssertFalse(window.ignoresMouseEvents)
        XCTAssertTrue(window.canBecomeKey)
        XCTAssertFalse(window.collectionBehavior.contains(.stationary))
        XCTAssertFalse(window.collectionBehavior.contains(.managed))
        XCTAssertTrue(window.collectionBehavior.contains(.transient))
        XCTAssertEqual(window.minSize, NoteGeometry.minimumSize)
        XCTAssertEqual(window.maxSize, NoteGeometry.maximumSize)
        controller.hide()
    }
}

@MainActor
private final class FakeTool: ToolModule {
    let descriptor: ToolDescriptor
    var events: [String] = []
    var openSettings: (() -> Void)?
    init(id: String) {
        descriptor = ToolDescriptor(id: id, name: id, summary: "", symbolName: "note.text", tint: .yellow)
    }
    func start() { events.append("start") }
    func stop() { events.append("stop") }
    func makeMenuItems() -> [NSMenuItem] { [NSMenuItem(title: "\(descriptor.name) command", action: nil, keyEquivalent: "")] }
    func makeSettingsView() -> AnyView { AnyView(EmptyView()) }
}

private func makeDefaults() throws -> (UserDefaults, String) {
    let suite = "MacToolsAppTests-\(UUID().uuidString)"
    return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
}
