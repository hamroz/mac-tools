import Combine
import Foundation
import KeyboardShortcuts
import MacToolsCore

extension KeyboardShortcuts.Name {
    /// No default: global shortcuts are the user's to choose.
    static let textAssistantImprove = Self("textAssistant.improve")
}

enum TextAssistantProviderKind: String, CaseIterable, Identifiable {
    /// The providers the user signed in to with OpenCode.
    case openCode
    /// OpenRouter with an API key kept in Mac Tools' Keychain item.
    case openRouter

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openCode: "OpenCode"
        case .openRouter: "OpenRouter API key"
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
    @Published var maxLength: Int { didSet { defaults.set(maxLength, forKey: Keys.maxLength) } }
    @Published var timeoutSeconds: Int { didSet { defaults.set(timeoutSeconds, forKey: Keys.timeout) } }

    private let defaults: UserDefaults

    private enum Keys {
        static let provider = "textAssistant.provider"
        static let openCodeModel = "textAssistant.openCodeModel"
        static let openRouterModel = "textAssistant.model"
        static let maxLength = "textAssistant.maxLength"
        static let timeout = "textAssistant.timeoutSeconds"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        provider = defaults.string(forKey: Keys.provider).flatMap(TextAssistantProviderKind.init(rawValue:)) ?? .openCode
        openCodeModel = defaults.string(forKey: Keys.openCodeModel) ?? ""
        openRouterModel = defaults.string(forKey: Keys.openRouterModel) ?? OpenRouterAPI.defaultModel
        let length = defaults.integer(forKey: Keys.maxLength)
        maxLength = Self.maxLengthChoices.contains(length) ? length : 8_000
        let timeout = defaults.integer(forKey: Keys.timeout)
        timeoutSeconds = Self.timeoutChoices.contains(timeout) ? timeout : 30
    }

    /// The model for the chosen provider, in that provider's own naming.
    var effectiveModel: String {
        switch provider {
        case .openCode:
            return openCodeModel.trimmingCharacters(in: .whitespacesAndNewlines)
        case .openRouter:
            let trimmed = openRouterModel.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? OpenRouterAPI.defaultModel : trimmed
        }
    }
}
