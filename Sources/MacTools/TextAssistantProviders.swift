import Foundation
import MacToolsCore

/// Turns a prompt into text. New back ends (an OpenAI-compatible endpoint,
/// the Anthropic API) conform to this.
protocol TextProvider: Sendable {
    func complete(_ request: TextCompletionRequest) async throws -> String
    /// Like `complete`, reporting the text so far as it arrives, for the preview.
    func stream(_ request: TextCompletionRequest, onPartial: @escaping @Sendable (String) -> Void) async throws -> String
}

extension TextProvider {
    /// Sources that can't stream answer all at once.
    func stream(_ request: TextCompletionRequest, onPartial: @escaping @Sendable (String) -> Void) async throws -> String {
        try await complete(request)
    }
}

/// The text received so far, shared with the code reading the stream.
final class StreamedText: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    private let onPartial: @Sendable (String) -> Void

    init(_ onPartial: @escaping @Sendable (String) -> Void) { self.onPartial = onPartial }

    var isEmpty: Bool { lock.withLock { text.isEmpty } }

    func append(_ piece: String) {
        let current = lock.withLock { text += piece; return text }
        onPartial(current)
    }
}

private func networkError(_ error: URLError) -> Error {
    switch error.code {
    case .cancelled: CancellationError()
    case .timedOut: TextAssistantError.timedOut
    default: TextAssistantError.network(error.localizedDescription)
    }
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

    func stream(_ request: TextCompletionRequest, onPartial: @escaping @Sendable (String) -> Void) async throws -> String {
        guard let key = apiKey()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw TextAssistantError.missingAPIKey
        }
        let urlRequest = try OpenRouterAPI.urlRequest(for: request, apiKey: key, timeout: timeout, stream: true)
        let streamed = StreamedText(onPartial)
        do {
            return try await receive(urlRequest, into: streamed)
        } catch let error as TextAssistantError where error.isTransient && streamed.isEmpty {
            // Retry only before anything is on screen, so the preview never restarts mid-sentence.
            try await Task.sleep(for: retryDelay)
            return try await receive(urlRequest, into: StreamedText(onPartial))
        }
    }

    private func receive(_ request: URLRequest, into streamed: StreamedText) async throws -> String {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                var body = Data()
                for try await byte in bytes { body.append(byte) }
                throw OpenRouterAPI.error(status: status, data: body)
            }
            var text = ""
            for try await line in bytes.lines {
                switch OpenRouterAPI.streamEvent(fromLine: line) {
                case .delta(let piece):
                    text += piece
                    streamed.append(piece)
                case .done: return try nonEmpty(text)
                case .failure(let error): throw error
                case .ignore: continue
                }
            }
            return try nonEmpty(text)
        } catch let error as URLError {
            throw networkError(error)
        }
    }

    private func nonEmpty(_ text: String) throws -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TextAssistantError.emptyResponse }
        return text
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

    func stream(_ request: TextCompletionRequest, onPartial: @escaping @Sendable (String) -> Void) async throws -> String {
        let (connection, providerID, modelID) = try await server.prepare(modelKey: request.model)
        let body = try OpenCodeAPI.messageBody(for: request, providerID: providerID, modelID: modelID)
        let streamed = StreamedText(onPartial)
        do {
            return try await send(body, to: connection, streamingInto: streamed)
        } catch let error as TextAssistantError where error.isTransient && streamed.isEmpty {
            try await Task.sleep(for: retryDelay)
            return try await send(body, to: connection, streamingInto: StreamedText(onPartial))
        }
    }

    /// OpenCode answers the message request when the reply is complete; the pieces
    /// arrive meanwhile on its event stream, which is opened first.
    private func send(_ body: Data, to connection: OpenCodeServer.Connection, streamingInto streamed: StreamedText?) async throws -> String {
        guard let streamed else { return try await send(body, to: connection) }
        let sessionID = try await createSession(connection)
        var eventsRequest = makeRequest(connection, "event", method: "GET")
        eventsRequest.timeoutInterval = max(timeout, 60)
        let (ready, readySignal) = AsyncStream<Void>.makeStream()
        let events = Task { [session] in
            guard let (bytes, _) = try? await session.bytes(for: eventsRequest) else { readySignal.finish(); return }
            readySignal.yield()
            for try await line in bytes.lines {
                if let piece = OpenCodeAPI.textDelta(fromEventLine: line, sessionID: sessionID) { streamed.append(piece) }
            }
        }
        defer { events.cancel() }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { for await _ in ready { return } }
            group.addTask { try? await Task.sleep(for: .seconds(2)) }
            await group.next()
            group.cancelAll()
        }
        return try await send(body, to: connection, session: sessionID)
    }

    private func send(_ body: Data, to connection: OpenCodeServer.Connection) async throws -> String {
        try await send(body, to: connection, session: try await createSession(connection))
    }

    private func send(_ body: Data, to connection: OpenCodeServer.Connection, session sessionID: String) async throws -> String {
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
