import AppKit
import XCTest
import MacToolsCore
@testable import MacTools

@MainActor
final class MenuBarOrganizerControllerTests: XCTestCase {
    private let key = MenuBarItemKey(rawValue: "id:com.example.tool")

    func test_HidesSelectedItemsOnlyWhileEnabled() async throws {
        let (defaults, suite) = try makeOrganizerDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let scanner = FakeMenuBarItemScanner()
        scanner.snapshots = [.testItem(), .testItem(key: "visible", x: 800)]
        let settings = MenuBarOrganizerSettings(defaults: defaults)
        let controller = makeOrganizerController(scanner, settings)
        controller.setHidden(true, for: key)
        XCTAssertTrue(scanner.movedPositions.isEmpty)
        controller.setEnabled(true)
        await waitUntil { !controller.isBusy }
        XCTAssertEqual(scanner.movedPositions.map(\.key), [key])
        XCTAssertTrue(controller.section.isCollapsed)
        XCTAssertLessThan(try XCTUnwrap(scanner.snapshots.first).frame.midX, 500)
        controller.stop()
    }

    func test_RevealCollapsesSpacerWithoutMovingEveryItem() async throws {
        let (defaults, suite) = try makeOrganizerDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let scanner = FakeMenuBarItemScanner()
        scanner.snapshots = [.testItem(x: 400)]
        let settings = MenuBarOrganizerSettings(defaults: defaults)
        settings.setHidden(true, for: key)
        let controller = makeOrganizerController(scanner, settings)
        controller.setEnabled(true)
        await waitUntil { !controller.isBusy }
        controller.revealAll()
        await waitUntil { !controller.isBusy }
        XCTAssertTrue(controller.isRevealed)
        XCTAssertFalse(controller.section.isCollapsed)
        controller.hideNow()
        await waitUntil { !controller.isBusy }
        XCTAssertTrue(controller.section.isCollapsed)
        XCTAssertTrue(scanner.movedPositions.isEmpty)
        controller.stop()
    }

    func test_OpenTemporarilyMovesItemToVisibleSectionThenReturnsIt() async throws {
        let (defaults, suite) = try makeOrganizerDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let scanner = FakeMenuBarItemScanner()
        scanner.snapshots = [.testItem(x: 400)]
        let settings = MenuBarOrganizerSettings(defaults: defaults)
        settings.setHidden(true, for: key)
        let controller = makeOrganizerController(scanner, settings)
        controller.setEnabled(true)
        await waitUntil { !controller.isBusy }
        controller.revealAndPress(key)
        await waitUntil { !controller.isBusy }
        XCTAssertEqual(scanner.pressedKeys, [key])
        XCTAssertTrue(controller.section.isCollapsed, "Opening one tray item must keep the rest hidden")
        XCTAssertGreaterThan(try XCTUnwrap(scanner.snapshots.first).frame.midX, 516)
        XCTAssertTrue(settings.isHidden(key))
        controller.hideNow()
        await waitUntil { !controller.isBusy }
        XCTAssertLessThan(try XCTUnwrap(scanner.snapshots.first).frame.midX, 500)
        XCTAssertTrue(controller.section.isCollapsed)
        controller.stop()
    }

    func test_ShowPreviouslyHiddenItemMovesItOutBeforeRemovingSelection() async throws {
        let (defaults, suite) = try makeOrganizerDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let scanner = FakeMenuBarItemScanner()
        scanner.snapshots = [.testItem(x: 400)]
        let settings = MenuBarOrganizerSettings(defaults: defaults)
        settings.setHidden(true, for: key)
        let controller = makeOrganizerController(scanner, settings)
        controller.setEnabled(true)
        await waitUntil { !controller.isBusy }
        controller.setHidden(false, for: key)
        await waitUntil { !controller.isBusy }
        XCTAssertFalse(settings.isHidden(key))
        XCTAssertGreaterThan(try XCTUnwrap(scanner.snapshots.first).frame.midX, 516)
        XCTAssertNil(controller.errorMessage)
        controller.stop()
    }

    func test_TemporaryRevealRestoresOriginalHiddenOrder() async throws {
        let (defaults, suite) = try makeOrganizerDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let scanner = FakeMenuBarItemScanner()
        let next = MenuBarItemKey(rawValue: "next")
        scanner.snapshots = [.testItem(x: 400), .testItem(key: next.rawValue, x: 440)]
        let settings = MenuBarOrganizerSettings(defaults: defaults)
        settings.setHidden(true, for: key)
        settings.setHidden(true, for: next)
        let controller = makeOrganizerController(scanner, settings)
        controller.setEnabled(true)
        await waitUntil { !controller.isBusy }
        controller.revealAndPress(key)
        await waitUntil { !controller.isBusy }
        controller.hideNow()
        await waitUntil { !controller.isBusy }
        XCTAssertEqual(scanner.scan().map(\.key), [key, next])
        XCTAssertTrue(controller.section.isCollapsed)
        controller.stop()
    }

    func test_FailedMovementDoesNotPretendItemWasHiddenOrSaveSelection() async throws {
        let (defaults, suite) = try makeOrganizerDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let scanner = FakeMenuBarItemScanner()
        scanner.snapshots = [.testItem()]
        scanner.moveChangesPosition = false
        let settings = MenuBarOrganizerSettings(defaults: defaults)
        let controller = makeOrganizerController(scanner, settings)
        controller.setEnabled(true)
        await waitUntil { !controller.isBusy }
        controller.setHidden(true, for: key)
        await waitUntil { !controller.isBusy }
        XCTAssertFalse(settings.isHidden(key))
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertFalse(controller.section.isCollapsed)
        XCTAssertTrue(controller.isRevealed)
        controller.stop()
    }

    func test_DisableAndPermissionRevocationAlwaysRemoveHiding() async throws {
        let (defaults, suite) = try makeOrganizerDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let scanner = FakeMenuBarItemScanner()
        scanner.snapshots = [.testItem(x: 400)]
        let settings = MenuBarOrganizerSettings(defaults: defaults)
        settings.setHidden(true, for: key)
        let section = FakeMenuBarSection()
        let controller = makeOrganizerController(scanner, settings, section: section)
        controller.setEnabled(true)
        await waitUntil { !controller.isBusy }
        XCTAssertTrue(section.isCollapsed)
        scanner.isTrusted = false
        controller.refresh()
        XCTAssertFalse(section.isCollapsed)
        controller.setEnabled(false)
        XCTAssertFalse(section.installed)
        XCTAssertTrue(settings.isHidden(key))
    }

    func test_UntrustedScannerMovesNothing() throws {
        let (defaults, suite) = try makeOrganizerDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let scanner = FakeMenuBarItemScanner()
        scanner.isTrusted = false
        scanner.snapshots = [.testItem()]
        let settings = MenuBarOrganizerSettings(defaults: defaults)
        let controller = makeOrganizerController(scanner, settings)
        controller.setEnabled(true)
        controller.refresh()
        XCTAssertFalse(controller.isTrusted)
        XCTAssertTrue(controller.items.isEmpty)
        XCTAssertTrue(scanner.movedPositions.isEmpty)
        XCTAssertFalse(scanner.didRequestAccess)
        controller.stop()
    }

    func test_DisablingCancelsPendingOpenWithoutLaterClick() async throws {
        let (defaults, suite) = try makeOrganizerDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let scanner = FakeMenuBarItemScanner()
        scanner.snapshots = [.testItem()]
        let settings = MenuBarOrganizerSettings(defaults: defaults)
        let controller = makeOrganizerController(scanner, settings)
        controller.pressDelay = .milliseconds(100)
        controller.setEnabled(true)
        await waitUntil { !controller.isBusy }
        controller.revealAndPress(key)
        controller.setEnabled(false)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(scanner.pressedKeys.isEmpty)
        XCTAssertFalse(controller.isRevealed)
        XCTAssertFalse(controller.isBusy)
    }

    func test_ArrangementReadsActualSidesAndPersistsAcrossRelaunch() async throws {
        let (defaults, suite) = try makeOrganizerDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let scanner = FakeMenuBarItemScanner()
        scanner.snapshots = [.testItem()]
        let settings = MenuBarOrganizerSettings(defaults: defaults)
        let controller = makeOrganizerController(scanner, settings)
        controller.setEnabled(true)
        await waitUntil { !controller.isBusy }
        controller.beginArrangement()
        await waitUntil { !controller.isBusy }
        scanner.snapshots = [.testItem(x: 400)]
        controller.finishArrangement()
        await waitUntil { !controller.isBusy }
        XCTAssertTrue(settings.isHidden(key))
        XCTAssertTrue(controller.section.isCollapsed)
        controller.stop()
        let restored = MenuBarOrganizerSettings(defaults: defaults)
        XCTAssertTrue(restored.isHidden(key))
        let second = makeOrganizerController(scanner, restored)
        second.start()
        await waitUntil { !second.isBusy }
        XCTAssertTrue(second.section.isCollapsed)
        second.stop()
    }

    func test_NewAppInstanceIsReconciledButOrdinaryRefreshDoesNotKeepDragging() async throws {
        let (defaults, suite) = try makeOrganizerDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let scanner = FakeMenuBarItemScanner()
        scanner.snapshots = [.testItem()]
        let settings = MenuBarOrganizerSettings(defaults: defaults)
        settings.setHidden(true, for: key)
        let controller = makeOrganizerController(scanner, settings)
        controller.setEnabled(true)
        await waitUntil { !controller.isBusy }
        controller.refresh()
        XCTAssertFalse(controller.isBusy)
        XCTAssertEqual(scanner.movedPositions.count, 1)
        var replacement = MenuBarItemSnapshot.testItem()
        replacement.processIdentifier = 42
        scanner.snapshots = [replacement]
        controller.refresh()
        await waitUntil { !controller.isBusy }
        XCTAssertEqual(scanner.movedPositions.count, 2)
        controller.stop()
    }

    func test_RecreatedStatusWindowInSameProcessIsReconciled() async throws {
        let (defaults, suite) = try makeOrganizerDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let scanner = FakeMenuBarItemScanner()
        var item = MenuBarItemSnapshot.testItem()
        item.processIdentifier = 42
        item.windowID = 100
        scanner.snapshots = [item]
        let settings = MenuBarOrganizerSettings(defaults: defaults)
        settings.setHidden(true, for: key)
        let controller = makeOrganizerController(scanner, settings)
        controller.setEnabled(true)
        await waitUntil { !controller.isBusy }
        item.windowID = 101
        scanner.snapshots = [item]
        controller.refresh()
        await waitUntil { !controller.isBusy }
        XCTAssertEqual(scanner.movedPositions.count, 2)
        XCTAssertTrue(controller.section.isCollapsed)
        controller.stop()
    }

    func test_WindowMatchingAccountsForGlyphPaddingAndRejectsWrongHost() {
        let glyph = CGRect(x: 1222, y: 8.5, width: 17.5, height: 22)
        let host = MenuBarWindowInfo(id: 21, pid: 1362, frame: CGRect(x: 1214, y: 0, width: 34, height: 39))
        XCTAssertEqual(MenuBarWindowCatalog.match(pid: 1362, frame: glyph, in: [host])?.id, 21)
        XCTAssertNil(MenuBarWindowCatalog.match(pid: 2000, frame: glyph, in: [host]),
                     "A stale source-app frame is not evidence of a Control Center hosted window's identity")
        let duplicate = MenuBarWindowInfo(id: 22, pid: 1362, frame: host.frame)
        XCTAssertNil(MenuBarWindowCatalog.match(pid: 1362, frame: glyph, in: [host, duplicate]))
    }

    func test_LegacySelectionMigratesWithoutLosingOtherPreferences() throws {
        let (defaults, suite) = try makeOrganizerDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = MenuBarOrganizerSettings(defaults: defaults)
        let legacy = MenuBarItemKey(rawValue: "app:com.example.tool|Changing 23%")
        settings.setHidden(true, for: legacy)
        settings.setHidden(true, for: MenuBarItemKey(rawValue: "other"))
        settings.migrate(legacy, to: key)
        XCTAssertTrue(settings.isHidden(key))
        XCTAssertFalse(settings.isHidden(legacy))
        XCTAssertEqual(MenuBarOrganizerSettings(defaults: defaults).hiddenKeys.count, 2)
    }

    func test_StartupAndRepeatedEnableDoNotRequestPermission() throws {
        let (defaults, suite) = try makeOrganizerDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let scanner = FakeMenuBarItemScanner()
        scanner.isTrusted = false
        let settings = MenuBarOrganizerSettings(defaults: defaults)
        settings.setEnabled(true)
        let controller = makeOrganizerController(scanner, settings)
        controller.start()
        controller.refresh()
        controller.stop()
        controller.start()
        controller.setEnabled(true)
        XCTAssertFalse(scanner.didRequestAccess)
        controller.requestAccess()
        XCTAssertTrue(scanner.didRequestAccess)
        controller.stop()
    }

    func test_ReversedSavedDividerAndArrowPositionsAreRepairedOnce() throws {
        let (defaults, suite) = try makeOrganizerDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let menu = "NSStatusItem Preferred Position MacTools.Organizer.Menu"
        let divider = "NSStatusItem Preferred Position MacTools.Organizer.Divider"
        defaults.set(677, forKey: menu)
        defaults.set(491, forKey: divider)
        MenuBarSection.prepareSavedPositions(defaults: defaults)
        XCTAssertEqual(defaults.double(forKey: menu), 491)
        XCTAssertEqual(defaults.double(forKey: divider), 677)
        MenuBarSection.prepareSavedPositions(defaults: defaults)
        XCTAssertEqual(defaults.double(forKey: menu), 491)
        XCTAssertEqual(defaults.double(forKey: divider), 677)
    }

    func test_FixedSystemItemDoesNotBlockHidingOtherApps() async throws {
        let (defaults, suite) = try makeOrganizerDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let scanner = FakeMenuBarItemScanner()
        var fixed = MenuBarItemSnapshot.testItem(key: "clock", x: 1000)
        fixed.canMove = false
        scanner.snapshots = [.testItem(), fixed]
        let settings = MenuBarOrganizerSettings(defaults: defaults)
        settings.setHidden(true, for: key)
        let controller = makeOrganizerController(scanner, settings)
        controller.setEnabled(true)
        await waitUntil { !controller.isBusy }
        XCTAssertTrue(controller.section.isCollapsed)
        XCTAssertEqual(scanner.movedPositions.map(\.key), [key])
        controller.refresh()
        XCTAssertFalse(controller.isBusy)
        controller.stop()
    }

    func test_AutoRehideAndRefusedDividerPlacement() async throws {
        let (defaults, suite) = try makeOrganizerDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let scanner = FakeMenuBarItemScanner()
        scanner.snapshots = [.testItem(x: 400)]
        let settings = MenuBarOrganizerSettings(defaults: defaults)
        settings.setHidden(true, for: key)
        let section = FakeMenuBarSection()
        let controller = makeOrganizerController(scanner, settings, section: section)
        controller.revealDuration = .milliseconds(40)
        controller.setEnabled(true)
        await waitUntil { !controller.isBusy }
        controller.revealAll()
        await waitUntil { controller.isRevealed }
        await waitUntil { section.isCollapsed && !controller.isBusy }
        controller.revealAll()
        await waitUntil { !controller.isBusy && !section.isCollapsed }
        section.collapseAllowed = false
        controller.hideNow()
        await waitUntil { !controller.isBusy }
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertTrue(controller.isRevealed)
        controller.stop()
    }
}
