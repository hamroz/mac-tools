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

    func test_RegistryExposesEveryToolAndRunsLifecycle() {
        let first = FakeTool(id: "first")
        let second = FakeTool(id: "second")
        let registry = ToolRegistry(modules: [first, second])
        let menu = registry.makeMenu()
        XCTAssertEqual(menu.items.filter { !$0.isSeparatorItem }.map(\.title), ["first", "first command", "second", "second command"])
        registry.startAll()
        registry.stopAll()
        XCTAssertEqual(first.events, ["start", "stop"])
        XCTAssertEqual(second.events, ["start", "stop"])
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
        XCTAssertGreaterThan(window.level.rawValue, Int(CGWindowLevelForKey(.desktopIconWindow)))
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
    init(id: String) { descriptor = ToolDescriptor(id: id, name: id, symbolName: "note.text") }
    func start() { events.append("start") }
    func stop() { events.append("stop") }
    func makeMenuItems() -> [NSMenuItem] { [NSMenuItem(title: "\(descriptor.name) command", action: nil, keyEquivalent: "")] }
    func showManager() {}
    func showSettings() {}
}
