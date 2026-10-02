import Foundation
import MacToolsCore

enum UsageServiceID: String, CaseIterable, Identifiable, Sendable {
    case claude
    case codex

    var id: String { rawValue }

    var name: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }

    var subtitle: String {
        switch self {
        case .claude: "Claude apps and Claude Code"
        case .codex: "ChatGPT Codex"
        }
    }

    var symbolName: String {
        switch self {
        case .claude: "sparkle"
        case .codex: "chevron.left.forwardslash.chevron.right"
        }
    }
}

protocol UsageFetching: Sendable {
    func fetch() async throws -> UsageSnapshot
}

enum UsageFetchError: LocalizedError, Equatable {
    case notSignedIn(String)
    case sessionExpired(String)
    case http(Int)
    case network(String)
    case unexpectedResponse

    var errorDescription: String? {
        switch self {
        case .notSignedIn(let hint), .sessionExpired(let hint): hint
        case .http(let status): "The service answered with an error (HTTP \(status)). Try again later."
        case .network(let message): "Couldn’t connect: \(message)"
        case .unexpectedResponse: "The service returned usage in an unexpected format. It may have changed."
        }
    }
}

// MARK: - Claude

/// Reads Claude Code's own sign-in and asks Anthropic for the limits `/usage` shows.
/// Claude apps and Claude Code share these limits.
struct ClaudeUsageFetcher: UsageFetching {
    var session: URLSession = .shared
    var now: @Sendable () -> Date = Date.init

    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let keychainService = "Claude Code-credentials"
    /// Only the Terminal `claude` command renews this sign-in; the desktop app keeps its own.
    private static let expired = UsageFetchError.sessionExpired(
        "Claude Code’s Terminal sign-in has expired. Run “claude” in Terminal once to renew it."
    )

    func fetch() async throws -> UsageSnapshot {
        guard let data = Self.storedCredentials(),
              let credentials = ClaudeUsageParser.credentials(from: data) else {
            throw UsageFetchError.notSignedIn("Sign in to Claude Code (run “claude” in Terminal) to see your Claude limits.")
        }

        if let expiresAt = credentials.expiresAt, expiresAt <= now() {
            throw Self.expired
        }

        var request = URLRequest(url: Self.endpoint, timeoutInterval: 20)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (body, status) = try await send(request, session: session)
        switch status {
        case 200:
            do { return try ClaudeUsageParser.parse(body, plan: credentials.plan, now: now()) }
            catch { throw UsageFetchError.unexpectedResponse }
        case 401, 403:
            throw Self.expired
        default:
            throw UsageFetchError.http(status)
        }
    }

    /// Claude Code stores its sign-in with `/usr/bin/security`, so reading it the
    /// same way matches the item's access list. Linux-style installs keep a file instead.
    private static func storedCredentials() -> Data? {
        if let output = runSecurity(["find-generic-password", "-s", keychainService, "-w"]), !output.isEmpty {
            return output
        }
        let file = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/.credentials.json")
        return try? Data(contentsOf: file)
    }

    private static func runSecurity(_ arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return data
    }
}

// MARK: - Codex

/// Reads Codex's sign-in and asks the ChatGPT backend for the limits `/status` shows.
/// Falls back to the most recent limits Codex wrote to its own session logs.
struct CodexUsageFetcher: UsageFetching {
    var session: URLSession = .shared
    var codexHome = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex")
    var now: @Sendable () -> Date = Date.init

    private static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    func fetch() async throws -> UsageSnapshot {
        do {
            return try await fetchLive()
        } catch {
            if let logged = latestLoggedSnapshot() { return logged }
            throw error
        }
    }

    private func fetchLive() async throws -> UsageSnapshot {
        guard let data = try? Data(contentsOf: codexHome.appending(path: "auth.json")),
              let credentials = CodexUsageParser.credentials(from: data) else {
            throw UsageFetchError.notSignedIn("Sign in to Codex with your ChatGPT account (run “codex login”) to see your Codex limits.")
        }

        var request = URLRequest(url: Self.endpoint, timeoutInterval: 20)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        if let account = credentials.accountID {
            request.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.setValue("codex_cli_rs", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (body, status) = try await send(request, session: session)
        switch status {
        case 200:
            do { return try CodexUsageParser.parse(body, now: now()) }
            catch { throw UsageFetchError.unexpectedResponse }
        case 401, 403:
            throw UsageFetchError.sessionExpired("Your Codex sign-in has expired. Open Codex once to renew it.")
        default:
            throw UsageFetchError.http(status)
        }
    }

    /// Scans only the newest few session logs; each Codex turn records the current limits.
    func latestLoggedSnapshot(maxFiles: Int = 6) -> UsageSnapshot? {
        let files = newestSessionFiles(limit: maxFiles)
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8),
                  let snapshot = CodexUsageParser.latestLogSnapshot(lines: text.split(separator: "\n"), now: now()) else { continue }
            return snapshot
        }
        return nil
    }

    /// Session logs live in `sessions/YYYY/MM/DD/rollout-….jsonl`; walk the newest folders first.
    private func newestSessionFiles(limit: Int) -> [URL] {
        let fileManager = FileManager.default
        func children(_ url: URL) -> [URL] {
            ((try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [])
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
        }
        var result: [URL] = []
        for year in children(codexHome.appending(path: "sessions")) {
            for month in children(year) {
                for day in children(month) {
                    result += children(day).filter { $0.pathExtension == "jsonl" }
                    if result.count >= limit { return Array(result.prefix(limit)) }
                }
            }
        }
        return result
    }
}

// MARK: - Shared

private func send(_ request: URLRequest, session: URLSession) async throws -> (Data, Int) {
    do {
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    } catch {
        throw UsageFetchError.network(error.localizedDescription)
    }
}
