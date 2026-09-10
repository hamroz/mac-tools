import AppKit
import XCTest
import MacToolsCore
@testable import MacTools

@MainActor
final class FakeMenuBarSection: MenuBarSectionControlling {
    var dividerFrame: CGRect? = CGRect(x: 500, y: 0, width: 16, height: 24)
    var isCollapsed = false
    var installed = false
    var collapseAllowed = true
    func install() { installed = true }
    func repairPlacement() async throws { }
    func setCollapsed(_ collapsed: Bool) { isCollapsed = collapsed && collapseAllowed }
    func remove() { installed = false; isCollapsed = false }
}

@MainActor
final class FakeMenuBarItemScanner: MenuBarItemScanning {
    var isTrusted = true
    var isInteracting = false
    var snapshots: [MenuBarItemSnapshot] = []
    var movedPositions: [(key: MenuBarItemKey, position: CGPoint)] = []
    var pressedKeys: [MenuBarItemKey] = []
    var didRequestAccess = false
    var didOpenPrivacySettings = false
    var moveChangesPosition = true
    var moveError: Error?
    var moveDelay: Duration = .zero
    var pressError: Error?
    func requestAccess() { didRequestAccess = true }
    func openPrivacySettings() { didOpenPrivacySettings = true }
    func scan() -> [MenuBarItemSnapshot] { snapshots.sorted { $0.position.x < $1.position.x } }
    func move(_ key: MenuBarItemKey, to position: CGPoint) async throws {
        movedPositions.append((key, position))
        try await Task.sleep(for: moveDelay)
        if let moveError { throw moveError }
        if moveChangesPosition, let index = snapshots.firstIndex(where: { $0.key == key }) {
            let item = snapshots[index]
            snapshots[index] = MenuBarItemSnapshot(
                key: item.key, title: item.title, appName: item.appName,
                bundleIdentifier: item.bundleIdentifier, icon: item.icon,
                position: CGPoint(x: position.x - item.size.width / 2, y: position.y - item.size.height / 2),
                size: item.size, processIdentifier: item.processIdentifier,
                legacyKey: item.legacyKey, canMove: item.canMove, windowID: item.windowID,
                hostProcessIdentifier: item.hostProcessIdentifier
            )
        }
    }
    func press(_ key: MenuBarItemKey) async throws {
        if let pressError { throw pressError }
        pressedKeys.append(key)
    }
}

extension MenuBarItemSnapshot {
    static func testItem(key: String = "id:com.example.tool", title: String = "Example", x: CGFloat = 700) -> MenuBarItemSnapshot {
        MenuBarItemSnapshot(key: MenuBarItemKey(rawValue: key), title: title, appName: "Example App",
                           bundleIdentifier: "com.example.tool", icon: nil,
                           position: CGPoint(x: x, y: 0), size: CGSize(width: 24, height: 24))
    }
}

extension XCTestCase {
    @MainActor
    func waitUntil(timeout: TimeInterval = 2, _ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "Timed out waiting for organizer operation")
    }
}

@MainActor
func makeOrganizerDefaults() throws -> (defaults: UserDefaults, suite: String) {
    let suite = "MacToolsMenuBarOrganizerTests-\(UUID().uuidString)"
    return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
}

@MainActor
func makeOrganizerController(_ scanner: FakeMenuBarItemScanner, _ settings: MenuBarOrganizerSettings,
                             section: FakeMenuBarSection = FakeMenuBarSection()) -> MenuBarOrganizerController {
    let controller = MenuBarOrganizerController(scanner: scanner, settings: settings, section: section)
    controller.layoutDelay = .zero
    controller.pressDelay = .zero
    return controller
}
