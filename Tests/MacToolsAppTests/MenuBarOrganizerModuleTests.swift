import AppKit
import XCTest
import MacToolsCore
@testable import MacTools

@MainActor
final class MenuBarOrganizerModuleTests: XCTestCase {
    private let key = MenuBarItemKey(rawValue: "id:com.example.tool")

    func test_MainMenuCheckboxTogglesEnablement() throws {
        _ = NSApplication.shared
        let (defaults, suite) = try makeOrganizerDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let scanner = FakeMenuBarItemScanner()
        let settings = MenuBarOrganizerSettings(defaults: defaults)
        let controller = makeOrganizerController(scanner, settings)
        let module = MenuBarOrganizerModule(settings: settings, controller: controller)

        let toggle = try XCTUnwrap(module.makeMenuItems().first { $0.title == "Enable Menu Bar Organizer" })
        XCTAssertEqual(toggle.state, .off)

        let action = try XCTUnwrap(toggle.action)
        XCTAssertTrue(NSApp.sendAction(action, to: toggle.target, from: toggle))
        XCTAssertTrue(settings.isEnabled)
        XCTAssertEqual(toggle.state, .on)

        XCTAssertTrue(NSApp.sendAction(action, to: toggle.target, from: toggle))
        XCTAssertFalse(settings.isEnabled)
        XCTAssertEqual(toggle.state, .off)
    }

    func test_OrganizerMenuListsHiddenItemsAndOpensThem() async throws {
        _ = NSApplication.shared
        let (defaults, suite) = try makeOrganizerDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let scanner = FakeMenuBarItemScanner()
        scanner.snapshots = [.testItem()]
        let settings = MenuBarOrganizerSettings(defaults: defaults)
        let controller = makeOrganizerController(scanner, settings)
        controller.pressDelay = .zero
        controller.setEnabled(true)
        await waitUntil { !controller.isBusy }
        controller.setHidden(true, for: key)
        await waitUntil { !controller.isBusy }

        let module = MenuBarOrganizerModule(settings: settings, controller: controller)
        let menu = module.makeOrganizerMenu()
        let hiddenItem = try XCTUnwrap(menu.items.first { $0.title == "Example" })

        let action = try XCTUnwrap(hiddenItem.action)
        XCTAssertTrue(NSApp.sendAction(action, to: hiddenItem.target, from: hiddenItem))
        await waitUntil { scanner.pressedKeys.contains(self.key) }
        XCTAssertEqual(scanner.pressedKeys, [key])
        controller.stop()
    }

    func test_OrganizerMenuShowsEmptyStateWhenNothingIsHidden() throws {
        _ = NSApplication.shared
        let (defaults, suite) = try makeOrganizerDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let scanner = FakeMenuBarItemScanner()
        scanner.snapshots = [.testItem()]
        let settings = MenuBarOrganizerSettings(defaults: defaults)
        let controller = makeOrganizerController(scanner, settings)
        let module = MenuBarOrganizerModule(settings: settings, controller: controller)

        let menu = module.makeOrganizerMenu()
        XCTAssertEqual(
            menu.items.filter { !$0.isSeparatorItem }.map(\.title),
            ["No Hidden Items", "Arrange in Menu Bar…", "Settings…"]
        )
    }

    func test_OrganizerMenuExplainsMissingAccessibilityAccess() throws {
        _ = NSApplication.shared
        let (defaults, suite) = try makeOrganizerDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let scanner = FakeMenuBarItemScanner()
        scanner.isTrusted = false
        let settings = MenuBarOrganizerSettings(defaults: defaults)
        let controller = makeOrganizerController(scanner, settings)
        let module = MenuBarOrganizerModule(settings: settings, controller: controller)

        let menu = module.makeOrganizerMenu()
        XCTAssertEqual(
            menu.items.filter { !$0.isSeparatorItem }.map(\.title),
            ["Accessibility Access Required", "Open System Settings…", "Settings…"]
        )

        let open = try XCTUnwrap(menu.items.first { $0.title == "Open System Settings…" })
        let action = try XCTUnwrap(open.action)
        XCTAssertTrue(NSApp.sendAction(action, to: open.target, from: open))
        XCTAssertTrue(scanner.didRequestAccess)
        XCTAssertTrue(scanner.didOpenPrivacySettings)
    }
}
