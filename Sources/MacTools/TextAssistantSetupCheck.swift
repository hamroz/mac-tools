import Combine
import Foundation
import MacToolsCore

/// Settings' Check Setup: verifies, one step at a time, everything a run needs,
/// ending with a real sample transformation. It never touches the clipboard
/// or sends keystrokes.
@MainActor
final class TextAssistantSetupCheck: ObservableObject {
    enum Status: Equatable {
        case waiting
        case running
        case passed(String)
        case failed(String)
        case skipped(String)
    }

    struct Step: Identifiable, Equatable {
        enum Kind: String, CaseIterable {
            case accessibility, provider, config, model

            var title: String {
                switch self {
                case .accessibility: "Accessibility"
                case .provider: "Model source"
                case .config: "Modes and tones"
                case .model: "Model test"
                }
            }
        }

        let kind: Kind
        var status: Status = .waiting
        var id: String { kind.rawValue }
    }

    nonisolated static let sampleText = "i has went to the store yesterday and buyed three apple"

    @Published private(set) var steps: [Step] = []
    @Published private(set) var isRunning = false

    private let settings: TextAssistantSettings
    private let configStore: TextAssistantConfigStore
    private let openCode: OpenCodeServer
    private let claudeCode: ClaudeCodeTool
    private let isAccessibilityTrusted: () -> Bool
    private let hasOpenRouterKey: () -> Bool
    private let makeProvider: (TextAssistantSettings) -> TextProvider
    private var task: Task<Void, Never>?

    init(
        settings: TextAssistantSettings,
        configStore: TextAssistantConfigStore,
        openCode: OpenCodeServer,
        claudeCode: ClaudeCodeTool = ClaudeCodeTool(),
        isAccessibilityTrusted: @escaping () -> Bool = { AccessibilityPermission.shared.refresh() },
        hasOpenRouterKey: @escaping () -> Bool = { KeychainStore.openRouterKey.hasValue },
        makeProvider: @escaping (TextAssistantSettings) -> TextProvider
    ) {
        self.settings = settings
        self.configStore = configStore
        self.openCode = openCode
        self.claudeCode = claudeCode
        self.isAccessibilityTrusted = isAccessibilityTrusted
        self.hasOpenRouterKey = hasOpenRouterKey
        self.makeProvider = makeProvider
    }

    var allPassed: Bool {
        !steps.isEmpty && steps.allSatisfy { if case .passed = $0.status { true } else { false } }
    }

    func run() {
        task?.cancel()
        steps = Step.Kind.allCases.map { Step(kind: $0) }
        isRunning = true
        task = Task { [weak self] in
            await self?.perform()
            self?.isRunning = false
        }
    }

    func waitUntilDone() async { await task?.value }

    private func perform() async {
        set(.accessibility, .running)
        set(.accessibility, isAccessibilityTrusted()
            ? .passed("Allowed: Text Assistant can read selections and paste results.")
            : .failed("Not allowed yet. Click Allow… in Permission below, then turn on Mac Tools in System Settings."))

        set(.provider, .running)
        let providerReady = await checkProvider()

        set(.config, .running)
        configStore.reloadIfChanged()
        let config = configStore.config
        let samples = configStore.styleSamples.map { "\($0.count.formatted()) characters of My style samples" } ?? "no My style samples yet"
        if let problem = configStore.problem {
            set(.config, .failed("\(problem) Using the last working version."))
        } else {
            set(.config, .passed("\(config.modes.count) modes and \(config.tones.count) tones; \(samples)."))
        }

        guard providerReady else {
            return set(.model, .skipped("Skipped until the model source is ready."))
        }
        set(.model, .running)
        guard let mode = config.mode(id: "fix") ?? config.modes.first,
              let tone = config.tone(id: "original") ?? config.tones.first else { return }
        let request = PromptBuilder.request(
            text: Self.sampleText, mode: mode, tone: tone, config: config,
            styleSamples: nil, model: settings.effectiveModel
        )
        let started = Date()
        do {
            let answer = try await makeProvider(settings).complete(request)
            let seconds = Date().timeIntervalSince(started).formatted(.number.precision(.fractionLength(1)))
            let text = TextAssistantOutput.reconcile(answer, original: Self.sampleText)
            set(.model, .passed("\(modelName) answered in \(seconds) s: “\(text)”"))
        } catch is CancellationError {
            set(.model, .skipped("Cancelled."))
        } catch {
            set(.model, .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
        }
    }

    private func checkProvider() async -> Bool {
        switch settings.provider {
        case .openRouter:
            guard hasOpenRouterKey() else {
                set(.provider, .failed("No OpenRouter API key saved. Add one above, or switch to OpenCode."))
                return false
            }
            set(.provider, .passed("OpenRouter API key saved in the Keychain."))
            return true
        case .claudeCode:
            await claudeCode.refresh()
            guard claudeCode.isInstalled else {
                set(.provider, .failed(TextAssistantError.claudeCodeNotInstalled.errorDescription!))
                return false
            }
            guard claudeCode.isSignedIn == true else {
                set(.provider, .failed(TextAssistantError.claudeCodeNotSignedIn.errorDescription!))
                return false
            }
            set(.provider, .passed("Claude Code \(claudeCode.version ?? "") is signed in."))
            return true
        case .openCode:
            if openCode.executable == nil { await openCode.locate() }
            guard openCode.isInstalled else {
                set(.provider, .failed(TextAssistantError.openCodeNotInstalled.errorDescription!))
                return false
            }
            await openCode.refreshModels()
            if let error = openCode.modelsError {
                set(.provider, .failed(error))
                return false
            }
            let providers = openCode.modelGroups.map(\.name).formatted(.list(type: .and))
            set(.provider, .passed("OpenCode \(openCode.version ?? "") is running, signed in to \(providers)."))
            return true
        }
    }

    private var modelName: String {
        let key = settings.effectiveModel
        switch settings.provider {
        case .openCode:
            if key.isEmpty { return openCode.modelGroups.preferredDefault(OpenCodeAPI.preferredModels)?.name ?? "The model" }
            return openCode.modelGroups.model(withKey: key)?.name ?? key
        case .openRouter:
            return key
        case .claudeCode:
            return ClaudeCodeCLI.models.first { $0.0 == key }?.1 ?? key
        }
    }

    private func set(_ kind: Step.Kind, _ status: Status) {
        guard let index = steps.firstIndex(where: { $0.kind == kind }) else { return }
        steps[index].status = status
    }
}
