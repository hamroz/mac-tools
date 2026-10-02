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

/// Uses the providers and sign-ins the user set up in OpenCode, through
/// Mac Tools' own OpenCode server. Each run is a throwaway session.
struct OpenCodeProvider: TextProvider {
    let server: OpenCodeServer
    var session: URLSession = .shared
    var timeout: TimeInterval = 30
    var retryDelay: Duration = .seconds(1)

    func complete(_ request: TextCompletionRequest) async throws -> String {
        let (connection, providerID, modelID) = try await server.prepare(modelKey: request.model)
        let body = try OpenCodeAPI.messageBody(for: request, providerID: providerID, modelID: modelID)
        do {
            return try await send(body, to: connection)
        } catch let error as TextAssistantError where error.isTransient {
            try await Task.sleep(for: retryDelay)
            return try await send(body, to: connection)
        }
    }

    private func send(_ body: Data, to connection: OpenCodeServer.Connection) async throws -> String {
        let sessionID = try await createSession(connection)
        defer {
            // Runs are not kept, even in Mac Tools' own OpenCode database.
            let request = makeRequest(connection, "session/\(sessionID)", method: "DELETE")
            Task.detached { [session] in _ = try? await session.data(for: request) }
        }
        var request = makeRequest(connection, "session/\(sessionID)/message", method: "POST")
        request.httpBody = body
        let (data, status) = try await withTaskCancellationHandler {
            try await perform(request)
        } onCancel: { [session] in
            let abort = makeRequest(connection, "session/\(sessionID)/abort", method: "POST")
            Task.detached { _ = try? await session.data(for: abort) }
        }
        return try OpenCodeAPI.messageText(status: status, data: data)
    }

    private func createSession(_ connection: OpenCodeServer.Connection) async throws -> String {
        var request = makeRequest(connection, "session", method: "POST")
        request.httpBody = Data(#"{"title":"Mac Tools Text Assistant"}"#.utf8)
        let (data, status) = try await perform(request)
        struct Created: Decodable { let id: String }
        guard status == 200, let created = try? JSONDecoder().decode(Created.self, from: data) else {
            throw TextAssistantError.openCodeUnavailable("it couldn’t open a session (HTTP \(status))")
        }
        return created.id
    }

    private func makeRequest(_ connection: OpenCodeServer.Connection, _ path: String, method: String) -> URLRequest {
        var request = URLRequest(url: connection.baseURL.appending(path: path), timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue(connection.authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func perform(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch let error as URLError {
            switch error.code {
            case .cancelled: throw CancellationError()
            case .timedOut: throw TextAssistantError.timedOut
            default: throw TextAssistantError.network(error.localizedDescription)
            }
        }
    }
}

/// OpenRouter's public model list, for choosing a model without typing its ID.
@MainActor
final class OpenRouterCatalog: ObservableObject {
    @Published private(set) var groups: [ModelGroup] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    func loadIfNeeded() async {
        guard groups.isEmpty, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let (data, _) = try await session.data(for: URLRequest(url: OpenRouterAPI.modelsEndpoint, timeoutInterval: 20))
            groups = try OpenRouterAPI.modelGroups(from: data)
            errorMessage = nil
        } catch {
            errorMessage = "Couldn’t load OpenRouter’s models: \(error.localizedDescription)"
        }
    }
}
