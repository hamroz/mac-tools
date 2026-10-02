import AppKit
import XCTest
import MacToolsCore
@testable import MacTools

@MainActor
final class TextAssistantRunnerTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!
    private var pasteboard: FakePasteboard!
    private var environment: FakeEnvironment!
    private var feedback: RecordingFeedback!
    private var configDirectory: URL!
    private var configStore: TextAssistantConfigStore!

    private let original = PasteboardSnapshot(items: [["public.utf8-plain-text": Data("mine".utf8), "public.rtf": Data("{\\rtf1 mine}".utf8)]])

    override func setUp() async throws {
        suite = "TextAssistantRunnerTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        pasteboard = FakePasteboard(original)
        environment = FakeEnvironment(pasteboard: pasteboard)
        feedback = RecordingFeedback()
        configDirectory = FileManager.default.temporaryDirectory.appending(path: "TextAssistantConfig-\(UUID().uuidString)")
        configStore = TextAssistantConfigStore(directory: configDirectory)
        configStore.reload()
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: configDirectory)
    }

    // MARK: Capture and replace

    func test_AccessibilitySelectionDoesNotTouchTheClipboard() async throws {
        environment.axSelection = "from ax"
        let captured = try await bridge().capture()
        XCTAssertEqual(captured, CapturedSelection(text: "from ax", appPID: 42, method: .accessibility))
        XCTAssertEqual(environment.posted, [])
        XCTAssertEqual(pasteboard.writes, 0)
    }

    func test_CopyFallbackReadsTheSelectionAndRestoresEveryClipboardType() async throws {
        environment.copySelection = "from copy"
        let captured = try await bridge().capture()
        XCTAssertEqual(captured.text, "from copy")
        XCTAssertEqual(captured.method, .copy)
        XCTAssertEqual(environment.posted, [.copy])
        XCTAssertEqual(pasteboard.snapshot(), original)
    }

    func test_NothingSelectedReportsItAndRestoresTheClipboard() async {
        await assertCaptureFails(with: .noSelection)
        XCTAssertEqual(pasteboard.snapshot(), original)
    }

    func test_SecureInputAndMissingPermissionStopBeforeCopying() async {
        environment.secureInput = true
        await assertCaptureFails(with: .secureInput)
        environment.secureInput = false
        environment.trusted = false
        await assertCaptureFails(with: .accessibilityNotTrusted)
        XCTAssertEqual(environment.posted, [])
    }

    func test_ReplacePastesThenRestoresTheClipboard() async throws {
        try await bridge().replace(CapturedSelection(text: "old", appPID: 42, method: .copy), with: "new")
        XCTAssertEqual(environment.pasted, ["new"])
        XCTAssertEqual(pasteboard.snapshot(), original)
    }

    func test_ReplaceKeepsWhatTheUserCopiedDuringThePaste() async throws {
        environment.onPaste = { $0.write("copied meanwhile", transient: false) }
        try await bridge().replace(CapturedSelection(text: "old", appPID: 42, method: .copy), with: "new")
        XCTAssertEqual(pasteboard.string(), "copied meanwhile")
    }

    // MARK: Runs

    func test_RunReplacesTheSelectionWithTheModelsAnswer() async {
        environment.copySelection = "helo wrld\n"
        let provider = FakeProvider { request in
            XCTAssertTrue(request.user.contains("helo wrld"))
            return "Hello, world.\n"
        }
        let runner = makeRunner(provider)

        runner.run(.improve)
        await runner.waitUntilIdle()

        XCTAssertEqual(environment.pasted, ["Hello, world.\n"])
        XCTAssertEqual(pasteboard.snapshot(), original)
        XCTAssertEqual(feedback.statuses, [.working("Improving…"), .success("Done")])
        XCTAssertEqual(runner.lastResult, "Hello, world.\n")
        XCTAssertFalse(runner.isRunning)
    }

    func test_ModelErrorLeavesTheClipboardUntouched() async {
        environment.copySelection = "text"
        let runner = makeRunner(FakeProvider { _ in throw TextAssistantError.invalidAPIKey })

        runner.run(.improve)
        await runner.waitUntilIdle()

        XCTAssertEqual(environment.pasted, [])
        XCTAssertEqual(pasteboard.snapshot(), original)
        XCTAssertEqual(feedback.statuses.last, .failure(TextAssistantError.invalidAPIKey.errorDescription!))
    }

    func test_ResultThatCantBePastedIsLeftOnTheClipboard() async {
        environment.copySelection = "text"
        let runner = makeRunner(FakeProvider { [environment] _ in
            await MainActor.run { environment?.frontmostPID = 7 }
            return "Better text"
        })

        runner.run(.improve)
        await runner.waitUntilIdle()

        XCTAssertEqual(environment.pasted, [])
        XCTAssertEqual(pasteboard.string(), "Better text")
        guard case .failure(let message) = feedback.statuses.last else { return XCTFail("Expected a failure") }
        XCTAssertTrue(message.contains("on the clipboard"))
    }

    func test_TooLongSelectionNeverReachesTheModel() async {
        let settings = TextAssistantSettings(defaults: defaults)
        settings.maxLength = 2_000
        environment.copySelection = String(repeating: "a", count: 2_001)
        let provider = FakeProvider { _ in "x" }
        let runner = makeRunner(provider, settings: settings)

        runner.run(.improve)
        await runner.waitUntilIdle()

        XCTAssertEqual(provider.calls, 0)
        XCTAssertEqual(feedback.statuses.last, .failure(TextAssistantError.textTooLong(limit: 2_000, actual: 2_001).errorDescription!))
    }

    func test_SecondPressCancelsTheRunInFlight() async {
        environment.copySelection = "text"
        let provider = FakeProvider { request in
            try await Task.sleep(for: .seconds(5))
            return "slow"
        }
        let runner = makeRunner(provider)

        runner.run(.improve)
        await waitUntil { provider.calls == 1 }
        provider.handler = { _ in "fast" }
        runner.run(.improve)
        await runner.waitUntilIdle()

        XCTAssertEqual(provider.calls, 2)
        XCTAssertEqual(environment.pasted, ["fast"])
        XCTAssertEqual(pasteboard.snapshot(), original)
        XCTAssertEqual(feedback.statuses.last, .success("Done"))
    }

    func test_UnchangedTextIsNotPasted() async {
        environment.copySelection = "Fine as is."
        let runner = makeRunner(FakeProvider { _ in "Fine as is." })

        runner.run(.improve)
        await runner.waitUntilIdle()

        XCTAssertEqual(environment.pasted, [])
        XCTAssertEqual(feedback.statuses.last, .success("Already looks good"))
    }

    // MARK: Modes, tones and quick actions

    func test_ModeToneAndStyleSamplesShapeThePrompt() async throws {
        try Data("## English\nyo, quick one: shipping friday 🚀".utf8).write(to: configStore.styleURL)
        configStore.reload()
        environment.copySelection = "Привет, как дела?"
        var system = ""
        let runner = makeRunner(FakeProvider { request in
            await MainActor.run { system = request.system }
            return "Hi, how are you?"
        })

        runner.run(TextAction(modeID: "translate", toneID: "my-style"))
        await runner.waitUntilIdle()

        XCTAssertEqual(feedback.statuses.first, .working("Translating…"))
        XCTAssertTrue(system.contains("Translate the text into English"), "Russian goes to English")
        XCTAssertTrue(system.contains("<style_samples>\n## English\nyo, quick one"))
        XCTAssertEqual(environment.pasted, ["Hi, how are you?"])
    }

    func test_StyleSamplesAreLeftOutForOtherTones() async {
        try? Data("## English\nmy sample".utf8).write(to: configStore.styleURL)
        configStore.reload()
        environment.copySelection = "text"
        var system = ""
        let runner = makeRunner(FakeProvider { request in
            await MainActor.run { system = request.system }
            return "Text."
        })

        runner.run(TextAction(modeID: "improve", toneID: "formal"))
        await runner.waitUntilIdle()

        XCTAssertTrue(system.contains("«Вы»"), "The Formal tone's instruction")
        XCTAssertFalse(system.contains("my sample"))
    }

    func test_ModeMissingFromConfigIsReportedWithoutTouchingTheSelection() async {
        environment.copySelection = "text"
        let provider = FakeProvider { _ in "x" }
        let runner = makeRunner(provider)

        runner.run(TextAction(modeID: "reply", toneID: "my-style"))
        await runner.waitUntilIdle()

        XCTAssertEqual(provider.calls, 0)
        XCTAssertEqual(environment.posted, [])
        guard case .failure(let message) = feedback.statuses.last else { return XCTFail("Expected a failure") }
        XCTAssertTrue(message.contains("“reply”"))
    }

    func test_ModeCanOverrideTheModel() async throws {
        var config = TextAssistantConfig.defaults
        config.modes[0].model = "deepseek/deepseek-flash"
        try config.encoded().write(to: configStore.configURL)
        configStore.reload()
        environment.copySelection = "text"
        var model = ""
        let runner = makeRunner(FakeProvider { request in
            await MainActor.run { model = request.model }
            return "Text."
        })

        runner.run(.improve)
        await runner.waitUntilIdle()

        XCTAssertEqual(model, "deepseek/deepseek-flash")
    }

    func test_QuickActionsDefaultWithoutShortcutsAndPersist() {
        let settings = TextAssistantSettings(defaults: defaults)
        XCTAssertEqual(settings.actions.map { $0.title(in: .defaults) },
                       ["Improve · My style", "Translate · My style", "Fix Grammar · Original tone", "Shorten · My style"])
        XCTAssertEqual(settings.actions.first?.shortcutName, .textAssistantImprove, "Phase 2's shortcut carries over")
        XCTAssertTrue(settings.actions.allSatisfy { $0.shortcutName.defaultShortcut == nil }, "No default shortcuts")

        let added = TextAction(modeID: "shorten", toneID: "formal")
        settings.actions = [settings.actions[0], added]
        XCTAssertEqual(TextAssistantSettings(defaults: defaults).actions, [TextAction.defaults[0], added])
        XCTAssertEqual(TextAction(modeID: "gone", toneID: "formal").title(in: .defaults), "“gone”? · Formal")
    }

    func test_SettingsDefaultToOpenCodeAndPersist() {
        let settings = TextAssistantSettings(defaults: defaults)
        XCTAssertEqual(settings.provider, .openCode)
        XCTAssertEqual(settings.effectiveModel, "", "Empty lets OpenCode pick a signed-in default")
        XCTAssertEqual(settings.maxLength, 8_000)
        XCTAssertEqual(settings.timeoutSeconds, 30)
        settings.openCodeModel = "opencode/claude-haiku-4-5"
        settings.openRouterModel = " google/gemini-3.1-flash-lite "
        settings.maxLength = 16_000
        let reloaded = TextAssistantSettings(defaults: defaults)
        XCTAssertEqual(reloaded.effectiveModel, "opencode/claude-haiku-4-5")
        reloaded.provider = .openRouter
        XCTAssertEqual(reloaded.effectiveModel, "google/gemini-3.1-flash-lite")
        XCTAssertEqual(reloaded.maxLength, 16_000)
        reloaded.openRouterModel = ""
        XCTAssertEqual(reloaded.effectiveModel, OpenRouterAPI.defaultModel)
        XCTAssertEqual(TextAssistantSettings(defaults: defaults).provider, .openRouter)
    }

    // MARK: Helpers

    private func bridge() -> TextSelectionBridge {
        TextSelectionBridge(pasteboard: pasteboard, environment: environment, timing: .init(
            modifierRelease: 0, copyTimeout: 0.2, pollInterval: 0.005, pasteSettle: 0.01
        ))
    }

    private func makeRunner(_ provider: FakeProvider, settings: TextAssistantSettings? = nil) -> TextAssistantRunner {
        TextAssistantRunner(
            settings: settings ?? TextAssistantSettings(defaults: defaults),
            configStore: configStore,
            bridge: bridge(),
            feedback: feedback,
            makeProvider: { _ in provider }
        )
    }

    private func assertCaptureFails(with expected: TextAssistantError, line: UInt = #line) async {
        do {
            _ = try await bridge().capture()
            XCTFail("Expected \(expected)", line: line)
        } catch {
            XCTAssertEqual(error as? TextAssistantError, expected, line: line)
        }
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

// MARK: - Fakes

@MainActor
private final class FakePasteboard: PasteboardAccess {
    private var items: [[String: Data]]
    private(set) var changeCount = 0
    private(set) var writes = 0

    init(_ snapshot: PasteboardSnapshot) { items = snapshot.items }

    func snapshot() -> PasteboardSnapshot { PasteboardSnapshot(items: items) }

    func restore(_ snapshot: PasteboardSnapshot) {
        items = snapshot.items
        bump()
    }

    func clear() {
        items = []
        bump()
    }

    func string() -> String? {
        items.first?["public.utf8-plain-text"].flatMap { String(data: $0, encoding: .utf8) }
    }

    func write(_ string: String, transient: Bool) {
        items = [["public.utf8-plain-text": Data(string.utf8)]]
        bump()
    }

    private func bump() {
        changeCount += 1
        writes += 1
    }
}

@MainActor
private final class FakeEnvironment: SelectionEnvironment {
    let pasteboard: FakePasteboard
    var trusted = true
    var secureInput = false
    var frontmostPID: pid_t = 42
    var axSelection: String?
    /// What the app puts on the clipboard for ⌘C; nil means nothing is selected.
    var copySelection: String?
    var onPaste: ((FakePasteboard) -> Void)?
    private(set) var posted: [CommandKey] = []
    private(set) var pasted: [String] = []

    init(pasteboard: FakePasteboard) { self.pasteboard = pasteboard }

    var isAccessibilityTrusted: Bool { trusted }
    var isSecureInputEnabled: Bool { secureInput }
    func frontmostAppPID() -> pid_t? { frontmostPID }
    func accessibilitySelectedText() -> String? { axSelection }
    func waitForModifierRelease(timeout: TimeInterval) async {}

    func post(_ key: CommandKey) {
        posted.append(key)
        switch key {
        case .copy:
            if let copySelection { pasteboard.write(copySelection, transient: false) }
        case .paste:
            pasted.append(pasteboard.string() ?? "")
            onPaste?(pasteboard)
        }
    }
}

private final class FakeProvider: TextProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var _handler: @Sendable (TextCompletionRequest) async throws -> String

    init(_ handler: @escaping @Sendable (TextCompletionRequest) async throws -> String) { _handler = handler }

    var calls: Int { lock.withLock { count } }

    var handler: @Sendable (TextCompletionRequest) async throws -> String {
        get { lock.withLock { _handler } }
        set { lock.withLock { _handler = newValue } }
    }

    func complete(_ request: TextCompletionRequest) async throws -> String {
        let handler = lock.withLock { count += 1; return _handler }
        return try await handler(request)
    }
}

@MainActor
private final class RecordingFeedback: TextAssistantFeedback {
    private(set) var statuses: [TextAssistantStatus] = []
    func show(_ status: TextAssistantStatus) { statuses.append(status) }
    func hide() {}
}

private extension TextAction {
    static let improve = TextAction.defaults[0]
}
