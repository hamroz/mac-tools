import Foundation
import MacToolsCore

/// Turns a prompt into text. New back ends (an OpenAI-compatible endpoint,
/// the Anthropic API, the Claude Code CLI) conform to this.
protocol TextProvider: Sendable {
    func complete(_ request: TextCompletionRequest) async throws -> String
}

struct OpenRouterProvider: TextProvider {
    var session: URLSession = .shared
    var timeout: TimeInterval = 30
    var apiKey: @Sendable () -> String? = { KeychainStore.openRouterKey.read() }
    /// Pause before the single automatic retry of a transient failure.
    var retryDelay: Duration = .seconds(1)

    func complete(_ request: TextCompletionRequest) async throws -> String {
        guard let key = apiKey()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw TextAssistantError.missingAPIKey
        }
        let urlRequest = try OpenRouterAPI.urlRequest(for: request, apiKey: key, timeout: timeout)
        do {
            return try await send(urlRequest)
        } catch let error as TextAssistantError where error.isTransient {
            try await Task.sleep(for: retryDelay)
            return try await send(urlRequest)
        }
    }

    private func send(_ request: URLRequest) async throws -> String {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .cancelled: throw CancellationError()
            case .timedOut: throw TextAssistantError.timedOut
            default: throw TextAssistantError.network(error.localizedDescription)
            }
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return try OpenRouterAPI.parse(status: status, data: data)
    }
}
