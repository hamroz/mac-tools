import AppKit
import XCTest
import MacToolsCore
@testable import MacTools

@MainActor
final class AIUsageTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suite = "AIUsageTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    func test_SettingsDefaultToVisibleWithBothServicesAndPersist() {
        let settings = AIUsageSettings(defaults: defaults)
        XCTAssertTrue(settings.showInMenuBar, "The menu bar icon is on by default")
        XCTAssertFalse(settings.showPercentInMenuBar)
        XCTAssertEqual(settings.refreshMinutes, 5)
        XCTAssertEqual(settings.enabledServices, [.claude, .codex])

        settings.showInMenuBar = false
        settings.refreshMinutes = 15
        settings.setEnabled(false, for: .codex)
        let reloaded = AIUsageSettings(defaults: defaults)
        XCTAssertFalse(reloaded.showInMenuBar)
        XCTAssertEqual(reloaded.refreshMinutes, 15)
        XCTAssertEqual(reloaded.enabledServices, [.claude])
    }

    func test_RefreshFillsEveryEnabledService() async {
        let claude = FakeFetcher(results: [.success(.sample(used: 40))])
        let codex = FakeFetcher(results: [.success(.sample(used: 90))])
        let store = AIUsageStore(settings: AIUsageSettings(defaults: defaults), fetchers: [.claude: claude, .codex: codex])

        store.refresh()
        await waitUntil { !store.isRefreshing }

        XCTAssertEqual(store.state(for: .claude).snapshot?.compactRemaining(), 60)
        XCTAssertEqual(store.state(for: .codex).snapshot?.compactRemaining(), 10)
        XCTAssertNotNil(store.lastRefresh)
        XCTAssertFalse(store.state(for: .claude).isLoading)
    }

    func test_FailedRefreshKeepsLastGoodNumbersAndReportsError() async {
        let claude = FakeFetcher(results: [.success(.sample(used: 25)), .failure(UsageFetchError.http(500))])
        let store = AIUsageStore(settings: AIUsageSettings(defaults: defaults), fetchers: [.claude: claude])

        store.refresh()
        await waitUntil { !store.isRefreshing }
        store.refresh()
        await waitUntil { !store.isRefreshing }

        let state = store.state(for: .claude)
        XCTAssertEqual(state.snapshot?.compactRemaining(), 75)
        XCTAssertEqual(state.errorMessage, UsageFetchError.http(500).localizedDescription)
    }

    func test_TurnedOffServiceIsNotFetched() async {
        let settings = AIUsageSettings(defaults: defaults)
        settings.setEnabled(false, for: .codex)
        let codex = FakeFetcher(results: [.success(.sample(used: 1))])
        let store = AIUsageStore(settings: settings, fetchers: [.claude: FakeFetcher(results: [.success(.sample(used: 1))]), .codex: codex])

        store.refresh()
        await waitUntil { !store.isRefreshing }

        XCTAssertEqual(codex.calls, 0)
        XCTAssertEqual(store.activeServices, [.claude])
    }

    func test_MenuBarIconFollowsSettingAndLeavesWhenToolStops() async {
        _ = NSApplication.shared
        let settings = AIUsageSettings(defaults: defaults)
        let store = AIUsageStore(settings: settings, fetchers: [.claude: FakeFetcher(results: [.success(.sample(used: 30))])])
        let module = AIUsageModule(settings: settings, store: store)

        module.start()
        XCTAssertTrue(module.isShownInMenuBar)
        settings.showInMenuBar = false
        XCTAssertFalse(module.isShownInMenuBar)
        settings.showInMenuBar = true
        XCTAssertTrue(module.isShownInMenuBar)

        module.stop()
        XCTAssertFalse(module.isShownInMenuBar)
    }

    func test_MacToolsMenuSummarizesEachService() async throws {
        _ = NSApplication.shared
        let settings = AIUsageSettings(defaults: defaults)
        settings.showInMenuBar = false
        let failing = FakeFetcher(results: [.failure(UsageFetchError.network("offline"))])
        let store = AIUsageStore(settings: settings, fetchers: [.claude: FakeFetcher(results: [.success(.sample(used: 30))]), .codex: failing])
        let module = AIUsageModule(settings: settings, store: store)
        let items = module.makeMenuItems()

        store.refresh()
        await waitUntil { !store.isRefreshing }

        XCTAssertEqual(items.map(\.title), [
            "Claude: 70% left · 5-hour session", "Codex: unavailable", "Show Usage…", "Refresh Usage",
        ])
        settings.setEnabled(false, for: .codex)
        XCTAssertTrue(try XCTUnwrap(items.first { $0.title.hasPrefix("Codex") }).isHidden)
    }

    func test_CodexFallsBackToItsOwnLogWhenOffline() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let day = home.appending(path: "sessions/2026/09/28")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let line = #"{"timestamp":"2026-09-28T11:00:00Z","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":3.0,"window_minutes":10080,"resets_at":4102444800}}}}"#
        try Data(line.utf8).write(to: day.appending(path: "rollout-2026-09-28T11-00-00-x.jsonl"))

        // No auth.json, so the live request is never made.
        let snapshot = try await CodexUsageFetcher(codexHome: home).fetch()
        XCTAssertEqual(snapshot.windows.map(\.title), ["Weekly limit"])
        XCTAssertEqual(snapshot.compactRemaining(), 97)
        guard case .localLog = snapshot.source else { return XCTFail("Expected the local log fallback") }
    }

    func test_CodexWithoutSignInOrLogsExplainsHowToSignIn() async {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            _ = try await CodexUsageFetcher(codexHome: home).fetch()
            XCTFail("Expected an error")
        } catch let error as UsageFetchError {
            guard case .notSignedIn = error else { return XCTFail("Unexpected \(error)") }
        } catch {
            XCTFail("Unexpected \(error)")
        }
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

private final class FakeFetcher: UsageFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<UsageSnapshot, Error>]
    private var count = 0

    init(results: [Result<UsageSnapshot, Error>]) { self.results = results }

    var calls: Int { lock.withLock { count } }

    func fetch() async throws -> UsageSnapshot {
        let result = lock.withLock { () -> Result<UsageSnapshot, Error> in
            count += 1
            return results.count > 1 ? results.removeFirst() : results[0]
        }
        return try result.get()
    }
}

private extension UsageSnapshot {
    static func sample(used: Double) -> UsageSnapshot {
        UsageSnapshot(windows: [
            UsageWindow(id: "five_hour", title: "5-hour session", usedPercent: used, resetsAt: Date().addingTimeInterval(3600)),
            UsageWindow(id: "seven_day", title: "Weekly · all models", usedPercent: used / 2, resetsAt: Date().addingTimeInterval(86_400)),
        ])
    }
}
