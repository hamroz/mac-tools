import XCTest
import MacToolsCore
@testable import MacTools

@MainActor
final class TextAssistantSetupCheckTests: XCTestCase {
    private var suite = ""
    private var settings: TextAssistantSettings!
    private var configStore: TextAssistantConfigStore!
    private var directory: URL!

    override func setUp() async throws {
        suite = "SetupCheck-\(UUID().uuidString)"
        settings = TextAssistantSettings(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        settings.provider = .openRouter
        directory = FileManager.default.temporaryDirectory.appending(path: suite)
        configStore = TextAssistantConfigStore(directory: directory)
        configStore.reload()
    }

    override func tearDown() async throws {
        UserDefaults().removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }

    private func check(trusted: Bool = true, key: Bool = true,
                       answer: @escaping @Sendable (TextCompletionRequest) async throws -> String) -> TextAssistantSetupCheck {
        TextAssistantSetupCheck(
            settings: settings, configStore: configStore,
            openCode: OpenCodeServer(supportDirectory: directory.appending(path: "OpenCode")),
            isAccessibilityTrusted: { trusted }, hasOpenRouterKey: { key },
            makeProvider: { _ in ClosureProvider(answer: answer) }
        )
    }

    func test_EverythingReadyRunsTheSampleThroughTheModel() async {
        let check = check { request in
            XCTAssertTrue(request.user.contains(TextAssistantSetupCheck.sampleText))
            XCTAssertTrue(request.system.contains("Fix only spelling"), "Uses the Fix Grammar mode")
            return "I went to the store yesterday and bought three apples."
        }
        check.run()
        await check.waitUntilDone()

        XCTAssertTrue(check.allPassed)
        XCTAssertFalse(check.isRunning)
        guard case .passed(let detail) = check.steps.last?.status else { return XCTFail("\(check.steps)") }
        XCTAssertTrue(detail.contains("bought three apples"))
    }

    func test_MissingPermissionAndKeyAreReportedAndTheModelIsSkipped() async {
        let check = check(trusted: false, key: false) { _ in XCTFail("No request without a key"); return "" }
        check.run()
        await check.waitUntilDone()

        XCTAssertEqual(check.steps.map(\.kind), [.accessibility, .provider, .config, .model])
        guard case .failed = check.steps[0].status, case .failed = check.steps[1].status,
              case .passed = check.steps[2].status, case .skipped = check.steps[3].status else {
            return XCTFail("\(check.steps)")
        }
        XCTAssertFalse(check.allPassed)
    }

    func test_ModelErrorsAreShownInPlainWords() async {
        let check = check { _ in throw TextAssistantError.invalidAPIKey }
        check.run()
        await check.waitUntilDone()

        XCTAssertEqual(check.steps.last?.status, .failed(TextAssistantError.invalidAPIKey.errorDescription!))
    }

    func test_BrokenConfigIsReportedWhileTheLastGoodOneKeepsWorking() async throws {
        try Data("{ not json".utf8).write(to: configStore.configURL)
        configStore.reload()
        let check = check { _ in "Fine." }
        check.run()
        await check.waitUntilDone()

        guard case .failed(let detail) = check.steps[2].status else { return XCTFail("\(check.steps)") }
        XCTAssertTrue(detail.contains("config.json isn’t valid"))
        guard case .passed = check.steps[3].status else { return XCTFail("The last good config still runs") }
    }
}

private struct ClosureProvider: TextProvider {
    let answer: @Sendable (TextCompletionRequest) async throws -> String
    func complete(_ request: TextCompletionRequest) async throws -> String { try await answer(request) }
}
