import XCTest
@testable import MacToolsCore

final class MenuShortcutCacheTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private var url: URL { directory.appendingPathComponent("Shortcuts/menu-shortcuts.json") }

    private func app(_ bundleID: String) -> CapturedApp {
        CapturedApp(
            bundleID: bundleID, name: "App \(bundleID)", capturedAt: Date(timeIntervalSince1970: 1_790_000_000),
            items: [MenuShortcut(path: ["File", "Export"], title: "PDF", combo: KeyCombo(keyCode: 35, modifiers: [.option, .command]), isEnabled: true)]
        )
    }

    func test_roundTrip() throws {
        let store = MenuShortcutCacheStore(url: url)
        let apps = ["a": app("a"), "b": app("b")]
        try store.save(apps)
        XCTAssertEqual(store.load(), apps)
    }

    func test_missingOrCorruptFileLoadsEmpty() throws {
        let store = MenuShortcutCacheStore(url: url)
        XCTAssertEqual(store.load(), [:])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("nope".utf8).write(to: url)
        XCTAssertEqual(store.load(), [:])
    }

    func test_forgetRemovesFile() throws {
        let store = MenuShortcutCacheStore(url: url)
        try store.save(["a": app("a")])
        store.forget()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(store.load(), [:])
    }

    func test_entriesUseMenuPath() throws {
        let entry = try XCTUnwrap(app("a").entries(isRunning: false).first)
        XCTAssertEqual(entry.detail, "File ▸ Export")
        XCTAssertEqual(entry.action, "PDF")
        XCTAssertEqual(entry.scope, .inApp)
        XCTAssertEqual(entry.source, .app(bundleID: "a", name: "App a"))
        XCTAssertFalse(entry.isSourceRunning)
    }

    func test_defaultURLIsInMacToolsSupportFolder() {
        XCTAssertTrue(MenuShortcutCacheStore.defaultURL.path.hasSuffix("Application Support/Mac Tools/Shortcuts/menu-shortcuts.json"))
    }
}
