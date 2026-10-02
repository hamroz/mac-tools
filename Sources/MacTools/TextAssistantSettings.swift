import Combine
import Foundation
import KeyboardShortcuts
import MacToolsCore

extension KeyboardShortcuts.Name {
    /// The first quick action's shortcut, by its original name.
    static let textAssistantImprove = TextAction.defaults[0].shortcutName
    /// Opens the popup. No default, like every Mac Tools shortcut.
    static let textAssistantPopup = Self("textAssistant.popup")
}

/// A mode and tone run straight from the menu or an optional shortcut.
struct TextAction: Codable, Hashable, Identifiable {
    var id: String
    var modeID: String
    var toneID: String

    init(id: String = UUID().uuidString, modeID: String, toneID: String) {
        self.id = id
        self.modeID = modeID
        self.toneID = toneID
    }

    /// "Improve · My style", or the IDs when config.json no longer has them.
    func title(in config: TextAssistantConfig) -> String {
        let mode = config.mode(id: modeID)?.name ?? "“\(modeID)”?"
        let tone = config.tone(id: toneID)?.name ?? "“\(toneID)”?"
        return "\(mode) · \(tone)"
    }

    /// Never has a default: global shortcuts are the user's to choose.
    var shortcutName: KeyboardShortcuts.Name { .init("textAssistant.\(id)") }

    /// The first action keeps Phase 2's "improve" ID, so a shortcut recorded for it carries over.
    static let defaults = [
        TextAction(id: "improve", modeID: "improve", toneID: "my-style"),
        TextAction(id: "translate", modeID: "translate", toneID: "my-style"),
        TextAction(id: "fix", modeID: "fix", toneID: "original"),
        TextAction(id: "shorten", modeID: "shorten", toneID: "my-style"),
    ]
}

enum TextAssistantProviderKind: String, CaseIterable, Identifiable {
    /// The providers the user signed in to with OpenCode.
    case openCode
    /// OpenRouter with an API key kept in Mac Tools' Keychain item.
    case openRouter
    /// `claude -p` with the user's Claude Code sign-in. Off unless chosen.
    case claudeCode

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openCode: "OpenCode"
        case .openRouter: "OpenRouter"
        case .claudeCode: "Claude Code"
        }
    }
}

enum TextAssistantOutputMode: String, CaseIterable, Identifiable {
    /// Paste the result over the selection right away.
    case replace
    /// Show the result first: Return replaces, ⌘C copies, Esc cancels.
    case preview

    var id: String { rawValue }

    var title: String {
        switch self {
        case .replace: "Replace"
        case .preview: "Preview first"
        }
    }
}

@MainActor
final class TextAssistantSettings: ObservableObject {
    static let maxLengthChoices = [2_000, 4_000, 8_000, 16_000, 32_000]
    static let timeoutChoices = [15, 30, 60, 120]

    @Published var provider: TextAssistantProviderKind { didSet { defaults.set(provider.rawValue, forKey: Keys.provider) } }
    /// `provider/model` as OpenCode names it; empty picks a fast default among the signed-in providers.
    @Published var openCodeModel: String { didSet { defaults.set(openCodeModel, forKey: Keys.openCodeModel) } }
    /// An OpenRouter model ID; empty means the default.
    @Published var openRouterModel: String { didSet { defaults.set(openRouterModel, forKey: Keys.openRouterModel) } }
    /// A Claude Code model alias: haiku, sonnet, or opus.
    @Published var claudeCodeModel: String { didSet { defaults.set(claudeCodeModel, forKey: Keys.claudeCodeModel) } }
    @Published var outputMode: TextAssistantOutputMode { didSet { defaults.set(outputMode.rawValue, forKey: Keys.outputMode) } }
    @Published var maxLength: Int { didSet { defaults.set(maxLength, forKey: Keys.maxLength) } }
    @Published var timeoutSeconds: Int { didSet { defaults.set(timeoutSeconds, forKey: Keys.timeout) } }
    @Published var actions: [TextAction] {
        didSet { defaults.set(try? JSONEncoder().encode(actions), forKey: Keys.actions) }
    }
    @Published var quickActionsEnabled: Bool { didSet { defaults.set(quickActionsEnabled, forKey: Keys.quickActionsEnabled) } }
    @Published var popupEnabled: Bool { didSet { defaults.set(popupEnabled, forKey: Keys.popupEnabled) } }
    /// The mode the popup starts on; empty means the last one used.
    @Published var popupModeID: String { didSet { defaults.set(popupModeID, forKey: Keys.popupMode) } }
    /// The tone the popup starts on; empty means the last one used.
    @Published var popupToneID: String { didSet { defaults.set(popupToneID, forKey: Keys.popupTone) } }
    private(set) var lastModeID: String? { didSet { defaults.set(lastModeID, forKey: Keys.lastMode) } }
    private(set) var lastToneID: String? { didSet { defaults.set(lastToneID, forKey: Keys.lastTone) } }

    private let defaults: UserDefaults

    private enum Keys {
        static let provider = "textAssistant.provider"
        static let openCodeModel = "textAssistant.openCodeModel"
        static let openRouterModel = "textAssistant.model"
        static let claudeCodeModel = "textAssistant.claudeCodeModel"
        static let outputMode = "textAssistant.outputMode"
        static let maxLength = "textAssistant.maxLength"
        static let timeout = "textAssistant.timeoutSeconds"
        static let actions = "textAssistant.actions"
        static let quickActionsEnabled = "textAssistant.quickActionsEnabled"
        static let popupEnabled = "textAssistant.popupEnabled"
        static let popupMode = "textAssistant.popupMode"
        static let popupTone = "textAssistant.popupTone"
        static let lastMode = "textAssistant.lastMode"
        static let lastTone = "textAssistant.lastTone"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        provider = defaults.string(forKey: Keys.provider).flatMap(TextAssistantProviderKind.init(rawValue:)) ?? .openCode
        openCodeModel = defaults.string(forKey: Keys.openCodeModel) ?? ""
        openRouterModel = defaults.string(forKey: Keys.openRouterModel) ?? OpenRouterAPI.defaultModel
        claudeCodeModel = defaults.string(forKey: Keys.claudeCodeModel) ?? ClaudeCodeCLI.defaultModel
        outputMode = defaults.string(forKey: Keys.outputMode).flatMap(TextAssistantOutputMode.init(rawValue:)) ?? .replace
        let length = defaults.integer(forKey: Keys.maxLength)
        maxLength = Self.maxLengthChoices.contains(length) ? length : 8_000
        let timeout = defaults.integer(forKey: Keys.timeout)
        timeoutSeconds = Self.timeoutChoices.contains(timeout) ? timeout : 30
        actions = defaults.data(forKey: Keys.actions).flatMap { try? JSONDecoder().decode([TextAction].self, from: $0) }
            ?? TextAction.defaults
        quickActionsEnabled = defaults.object(forKey: Keys.quickActionsEnabled) as? Bool ?? true
        popupEnabled = defaults.object(forKey: Keys.popupEnabled) as? Bool ?? true
        popupModeID = defaults.string(forKey: Keys.popupMode) ?? ""
        popupToneID = defaults.string(forKey: Keys.popupTone) ?? "my-style"
        lastModeID = defaults.string(forKey: Keys.lastMode)
        lastToneID = defaults.string(forKey: Keys.lastTone)
    }

    /// Where the popup starts: the chosen defaults, or the last used, and always something that exists.
    func popupStart(in config: TextAssistantConfig) -> (modeID: String, toneID: String) {
        func pick(_ preferred: String, last: String?, fallback: String?, in ids: [String]) -> String {
            let wanted = preferred.isEmpty ? last : preferred
            if let wanted, ids.contains(wanted) { return wanted }
            if let fallback, ids.contains(fallback) { return fallback }
            return ids.first ?? ""
        }
        return (
            pick(popupModeID, last: lastModeID, fallback: nil, in: config.modes.map(\.id)),
            pick(popupToneID, last: lastToneID, fallback: "my-style", in: config.tones.map(\.id))
        )
    }

    func rememberPopupChoice(modeID: String, toneID: String) {
        lastModeID = modeID
        lastToneID = toneID
    }

    /// The model for the chosen provider, in that provider's own naming.
    var effectiveModel: String {
        switch provider {
        case .openCode:
            return openCodeModel.trimmingCharacters(in: .whitespacesAndNewlines)
        case .openRouter:
            let trimmed = openRouterModel.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? OpenRouterAPI.defaultModel : trimmed
        case .claudeCode:
            return claudeCodeModel.isEmpty ? ClaudeCodeCLI.defaultModel : claudeCodeModel
        }
    }
}
