import Combine
import Foundation
import KeyboardShortcuts
import MacToolsCore

extension KeyboardShortcuts.Name {
    /// No default: global shortcuts are the user's to choose.
    static let textAssistantImprove = Self("textAssistant.improve")
}

@MainActor
final class TextAssistantSettings: ObservableObject {
    static let maxLengthChoices = [2_000, 4_000, 8_000, 16_000, 32_000]
    static let timeoutChoices = [15, 30, 60, 120]

    /// The OpenRouter model ID; empty means the default.
    @Published var model: String { didSet { defaults.set(model, forKey: Keys.model) } }
    @Published var maxLength: Int { didSet { defaults.set(maxLength, forKey: Keys.maxLength) } }
    @Published var timeoutSeconds: Int { didSet { defaults.set(timeoutSeconds, forKey: Keys.timeout) } }

    private let defaults: UserDefaults

    private enum Keys {
        static let model = "textAssistant.model"
        static let maxLength = "textAssistant.maxLength"
        static let timeout = "textAssistant.timeoutSeconds"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        model = defaults.string(forKey: Keys.model) ?? OpenRouterAPI.defaultModel
        let length = defaults.integer(forKey: Keys.maxLength)
        maxLength = Self.maxLengthChoices.contains(length) ? length : 8_000
        let timeout = defaults.integer(forKey: Keys.timeout)
        timeoutSeconds = Self.timeoutChoices.contains(timeout) ? timeout : 30
    }

    var effectiveModel: String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? OpenRouterAPI.defaultModel : trimmed
    }
}
