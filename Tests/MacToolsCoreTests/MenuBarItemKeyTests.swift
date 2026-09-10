import XCTest
import MacToolsCore

final class MenuBarItemKeyTests: XCTestCase {
    func test_IdentifierTakesPrecedence() {
        let key = MenuBarItemKey(
            identifier: "com.apple.menuextra.clock",
            bundleIdentifier: "com.apple.controlcenter",
            title: "Clock"
        )
        XCTAssertEqual(key.rawValue, "app:com.apple.controlcenter|id:com.apple.menuextra.clock")
    }

    func test_FallsBackToBundleIdentifierAndTitle() {
        let key = MenuBarItemKey(identifier: "", bundleIdentifier: "com.example.app", title: "Sync")
        XCTAssertEqual(key.rawValue, "app:com.example.app|Sync")
    }

    func test_MissingOwnerUsesStablePlaceholder() {
        XCTAssertEqual(
            MenuBarItemKey(identifier: "  ", bundleIdentifier: nil, title: " Sync ").rawValue,
            "app:unknown|Sync"
        )
        XCTAssertEqual(
            MenuBarItemKey(identifier: "", bundleIdentifier: "   ", title: "Sync").rawValue,
            "app:unknown|Sync"
        )
    }

    func test_SameInputsProduceEqualKeysAndDifferentAppsDoNot() {
        let first = MenuBarItemKey(identifier: "", bundleIdentifier: "com.example.a", title: "Tool")
        let same = MenuBarItemKey(identifier: "", bundleIdentifier: "com.example.a", title: "Tool")
        let otherApp = MenuBarItemKey(identifier: "", bundleIdentifier: "com.example.b", title: "Tool")

        XCTAssertEqual(first, same)
        XCTAssertNotEqual(first, otherApp)
    }

    func test_IdenticalAXIdentifiersInDifferentAppsDoNotCollide() {
        let a = MenuBarItemKey(identifier: "statusItem", bundleIdentifier: "com.example.a", title: "CPU 1%")
        let b = MenuBarItemKey(identifier: "statusItem", bundleIdentifier: "com.example.b", title: "CPU 1%")
        let changedTitle = MenuBarItemKey(identifier: "statusItem", bundleIdentifier: "com.example.a", title: "CPU 99%")
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a, changedTitle)
    }

    func test_RawValuesRoundTripThroughStoredStrings() {
        let keys: Set<MenuBarItemKey> = [
            MenuBarItemKey(identifier: "com.apple.menuextra.battery", bundleIdentifier: nil, title: ""),
            MenuBarItemKey(identifier: "", bundleIdentifier: "com.example.app", title: "Sync")
        ]
        let restored = Set(keys.map(\.rawValue).map(MenuBarItemKey.init(rawValue:)))
        XCTAssertEqual(keys, restored)
    }
}
