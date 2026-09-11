import AppKit
import XCTest
import MacToolsCore
@testable import MacTools

@MainActor
final class MenuBarOrganizerRecoveryTests: XCTestCase {
    func test_ShowHideAndReorderNeverExpandOtherHiddenItems() async throws {
        let (defaults, suite) = try makeOrganizerDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let scanner = FakeMenuBarItemScanner()
        scanner.snapshots = [.testItem(key: "one", x: 350), .testItem(key: "two", x: 400), .testItem(key: "three", x: 440)]
        let settings = MenuBarOrganizerSettings(defaults: defaults)
        for item in scanner.snapshots { settings.setHidden(true, for: item.key) }
        let section = FakeMenuBarSection()
        let controller = makeOrganizerController(scanner, settings, section: section)
        controller.setEnabled(true)
        await waitUntil { !controller.isBusy }
        section.collapseHistory = []
        let two = MenuBarItemKey(rawValue: "two")
        controller.setHidden(false, for: two)
        await waitUntil { !controller.isBusy }
        XCTAssertTrue(section.isCollapsed)
        XCTAssertFalse(settings.isHidden(two))
        controller.setHidden(true, for: two)
        await waitUntil { !controller.isBusy }
        controller.moveItem(two, earlier: true)
        await waitUntil { !controller.isBusy }
        XCTAssertFalse(section.collapseHistory.contains(false), "An intermediate expansion causes the visible flash")
        XCTAssertTrue(section.isCollapsed)
        XCTAssertNil(controller.errorMessage)
        controller.stop()
    }

    func test_NewNowPlayingWindowDoesNotRevealGroupOrInterruptOpenItem() async throws {
        let (defaults, suite) = try makeOrganizerDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let scanner = FakeMenuBarItemScanner()
        let item = MenuBarItemSnapshot.testItem(x: 400)
        scanner.snapshots = [item]
        let settings = MenuBarOrganizerSettings(defaults: defaults)
        settings.setHidden(true, for: item.key)
        let section = FakeMenuBarSection()
        let controller = makeOrganizerController(scanner, settings, section: section)
        controller.setEnabled(true)
        await waitUntil { !controller.isBusy }
        controller.revealAndPress(item.key)
        await waitUntil { !controller.isBusy }
        section.collapseHistory = []
        var playing = MenuBarItemSnapshot.testItem(key: "nowPlaying", x: 800)
        playing.windowID = 99
        scanner.snapshots.append(playing)
        controller.refresh()
        await waitUntil { !controller.isBusy }
        XCTAssertGreaterThan(try XCTUnwrap(scanner.snapshots.first).frame.midX, 516)
        XCTAssertFalse(section.collapseHistory.contains(false))
        controller.hideNow()
        await waitUntil { !controller.isBusy }
        XCTAssertLessThan(try XCTUnwrap(scanner.snapshots.first).frame.midX, 500)
        XCTAssertFalse(section.collapseHistory.contains(false))
        controller.stop()
    }

    func test_FailedSingleItemMoveKeepsExistingHiddenGroupCollapsed() async throws {
        let (defaults, suite) = try makeOrganizerDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let scanner = FakeMenuBarItemScanner()
        let item = MenuBarItemSnapshot.testItem(x: 400)
        scanner.snapshots = [item]
        let settings = MenuBarOrganizerSettings(defaults: defaults)
        settings.setHidden(true, for: item.key)
        let section = FakeMenuBarSection()
        let controller = makeOrganizerController(scanner, settings, section: section)
        controller.setEnabled(true)
        await waitUntil { !controller.isBusy }
        section.collapseHistory = []
        scanner.moveError = MenuBarOperationError.unavailable
        controller.setHidden(false, for: item.key)
        await waitUntil { !controller.isBusy }
        XCTAssertTrue(settings.isHidden(item.key))
        XCTAssertTrue(section.isCollapsed)
        XCTAssertFalse(section.collapseHistory.contains(false))
        XCTAssertNotNil(controller.errorMessage)
        controller.stop()
    }

    func test_RemovedItemRemainsRecoverableAfterRestartWithItsPreference() throws {
        let (defaults, suite) = try makeOrganizerDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let scanner = FakeMenuBarItemScanner()
        let item = MenuBarItemSnapshot.testItem()
        scanner.snapshots = [item]
        let settings = MenuBarOrganizerSettings(defaults: defaults)
        settings.setHidden(true, for: item.key)
        let first = makeOrganizerController(scanner, settings)
        first.refresh()
        scanner.snapshots = []
        first.refresh()
        XCTAssertTrue(first.missingItems.contains { $0.key == item.key })
        let restoredSettings = MenuBarOrganizerSettings(defaults: defaults)
        let second = makeOrganizerController(scanner, restoredSettings)
        XCTAssertTrue(second.missingItems.contains { $0.key == item.key })
        XCTAssertTrue(restoredSettings.isHidden(item.key))
    }

    func test_RecoveryWaitsForRealItemAndPreservesItsHiddenChoice() async throws {
        let (defaults, suite) = try makeOrganizerDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let scanner = FakeMenuBarItemScanner()
        let item = MenuBarItemSnapshot.testItem()
        let settings = MenuBarOrganizerSettings(defaults: defaults)
        settings.remember([item])
        settings.setHidden(true, for: item.key)
        let recovery = FakeMenuBarRecovery()
        recovery.onRestore = { scanner.snapshots = [item] }
        let section = FakeMenuBarSection()
        let controller = MenuBarOrganizerController(scanner: scanner, settings: settings, section: section, recovery: recovery)
        controller.layoutDelay = .zero
        controller.setEnabled(true)
        controller.restoreMissingItem(MenuBarRecoveryItem(item))
        await waitUntil { !controller.isBusy }
        XCTAssertEqual(recovery.restored.count, 1)
        XCTAssertTrue(controller.hiddenItems.contains { $0.key == item.key })
        XCTAssertFalse(controller.missingItems.contains { $0.key == item.key })
        XCTAssertTrue(section.isCollapsed)
        XCTAssertTrue(controller.recoveryMessage?.contains("hidden tray") == true)
        controller.stop()
    }

    func test_SystemRecoverySeedsDeduplicateAgainstActualAXIdentity() throws {
        let sound = MenuBarRecoveryItem(id: "app:com.apple.controlcenter|id:com.apple.menuextra.sound", title: "Sound",
                                        appName: "Control Center", bundleIdentifier: "com.apple.controlcenter")
        XCTAssertEqual(sound.systemSettingID, "controlcenter-sound-id")
        XCTAssertEqual(MenuBarRecoveryItem.commonSystemItems.first?.recoveryIdentity, sound.recoveryIdentity)
        let playing = try XCTUnwrap(MenuBarRecoveryItem.commonSystemItems.first { $0.title == "Now Playing" })
        XCTAssertEqual(playing.systemSettingID, "controlcenter-nowPlaying-id")
        let legacyAirDrop = MenuBarRecoveryItem(id: "app:com.apple.controlcenter|id:com.apple.menuextra.airdrop",
                                               title: "ControlCenter", appName: "ControlCenter", bundleIdentifier: "com.apple.controlcenter")
        XCTAssertEqual(legacyAirDrop.displayName, "AirDrop")
    }

    func test_RecoveryFailureFeedbackSurvivesAutomaticRefresh() async throws {
        let (defaults, suite) = try makeOrganizerDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let scanner = FakeMenuBarItemScanner()
        let settings = MenuBarOrganizerSettings(defaults: defaults)
        let recovery = FakeMenuBarRecovery()
        recovery.failure = MenuBarOperationError.unavailable
        let controller = MenuBarOrganizerController(scanner: scanner, settings: settings,
                                                     section: FakeMenuBarSection(), recovery: recovery)
        controller.layoutDelay = .zero
        controller.setEnabled(true)
        controller.restoreMissingItem(try XCTUnwrap(MenuBarRecoveryItem.commonSystemItems.first))
        await waitUntil { !controller.isBusy }
        let message = try XCTUnwrap(controller.recoveryMessage)
        scanner.snapshots = [.testItem()]
        controller.refresh()
        await waitUntil { !controller.isBusy }
        XCTAssertEqual(controller.recoveryMessage, message)
        controller.stop()
    }

    func test_RecoveryProbeRequiresOneNewUnidentifiedOverflowWindow() {
        let hidden = CGRect(x: -1000, y: 0, width: 34, height: 33)
        let existing = MenuBarWindowInfo(id: 10, pid: 100, frame: hidden)
        let restored = MenuBarWindowInfo(id: 20, pid: 100, frame: hidden.offsetBy(dx: 40, dy: 0))
        let other = MenuBarWindowInfo(id: 30, pid: 100, frame: hidden.offsetBy(dx: 80, dy: 0))
        XCTAssertEqual(MenuBarWindowCatalog.recoveryCandidate(in: [existing, restored], excluding: [10])?.id, 20)
        XCTAssertNil(MenuBarWindowCatalog.recoveryCandidate(in: [existing], excluding: [10]))
        XCTAssertNil(MenuBarWindowCatalog.recoveryCandidate(in: [existing, restored, other], excluding: [10]), "Simultaneous new windows must not be guessed")
        let divider = MenuBarWindowInfo(id: 40, pid: 100, frame: hidden, title: "MacTools.Organizer.Divider")
        XCTAssertNil(MenuBarWindowCatalog.recoveryCandidate(in: [divider], excluding: []))
    }
}
