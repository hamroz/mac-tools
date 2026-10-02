import AppKit
import Combine
import Darwin
import MacToolsCore

/// Mac Tools' own `opencode serve`, started on first use and stopped when idle.
/// It reads the user's OpenCode sign-ins (~/.local/share/opencode/auth.json)
/// but keeps its sessions in a separate database, out of the user's history,
/// and listens on 127.0.0.1 behind a password made fresh for each launch.
@MainActor
final class OpenCodeServer: ObservableObject {
    enum State: Equatable {
        case stopped
        case starting
        case running
        case failed(String)
    }

    struct Connection: Sendable {
        let baseURL: URL
        let authorization: String
    }

    @Published private(set) var state: State = .stopped
    /// nil until located; `.some(nil)` means OpenCode isn't installed.
    @Published private(set) var executable: URL??
    @Published private(set) var version: String?
    @Published private(set) var modelGroups: [ModelGroup] = []
    @Published private(set) var isLoadingModels = false
    @Published private(set) var modelsError: String?

    var idleTimeout: TimeInterval = 600

    private let supportDirectory: URL
    private var process: Process?
    private var connection: Connection?
    private var starting: Task<Connection, Error>?
    private var idleTask: Task<Void, Never>?
    private var shellPath: String?
    private let session: URLSession

    init(supportDirectory: URL = OpenCodeServer.defaultSupportDirectory, session: URLSession = .shared) {
        self.supportDirectory = supportDirectory
        self.session = session
    }

    static var defaultSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Mac Tools/Text Assistant/OpenCode", directoryHint: .isDirectory)
    }

    var isInstalled: Bool { (executable ?? nil) != nil }

    // MARK: Locating OpenCode

    /// Finds the `opencode` command where installers put it, then through a login shell.
    func locate() async {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/opencode", "/usr/local/bin/opencode", "\(home)/.opencode/bin/opencode",
            "\(home)/.local/bin/opencode", "\(home)/.bun/bin/opencode", "\(home)/.npm-global/bin/opencode",
        ]
        let shell = await Self.loginShellLookup()
        shellPath = shell.path
        let found = candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? shell.opencode
        let url = found.map { URL(fileURLWithPath: $0) }
        executable = .some(url)
        version = nil
        if let url { version = await Self.run(url, ["--version"], timeout: 10)?.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func loginShellLookup() async -> (opencode: String?, path: String?) {
        let marker = "__MACTOOLS__"
        let script = "echo \(marker)$(command -v opencode); echo \(marker)$PATH"
        guard let output = await run(URL(fileURLWithPath: "/bin/zsh"), ["-lic", script], timeout: 8) else { return (nil, nil) }
        let values = output.components(separatedBy: "\n").filter { $0.hasPrefix(marker) }.map { String($0.dropFirst(marker.count)) }
        let opencode = values.first.flatMap { $0.hasPrefix("/") ? $0 : nil }
        return (opencode, values.count > 1 ? values[1] : nil)
    }

    // MARK: Lifecycle

    /// The running server, starting it when needed. Each call postpones the idle shutdown.
    func connect() async throws -> Connection {
        scheduleIdleStop()
        if let connection, process?.isRunning == true { return connection }
        if let starting { return try await starting.value }
        if executable == nil { await locate() }
        guard let executable = executable ?? nil else { throw TextAssistantError.openCodeNotInstalled }

        state = .starting
        let task = Task { try await launch(executable) }
        starting = task
        defer { starting = nil }
        do {
            let connection = try await task.value
            self.connection = connection
            state = .running
            return connection
        } catch {
            state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            throw error
        }
    }

    func stop() {
        idleTask?.cancel()
        idleTask = nil
        starting?.cancel()
        if let process, process.isRunning { Self.terminateTree(process.processIdentifier) }
        process = nil
        connection = nil
        try? FileManager.default.removeItem(at: pidFile)
        state = .stopped
    }

    private func scheduleIdleStop() {
        idleTask?.cancel()
        let timeout = idleTimeout
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    private var pidFile: URL { supportDirectory.appending(path: "server.pid") }

    private func launch(_ executable: URL) async throws -> Connection {
        let fileManager = FileManager.default
        let workspace = supportDirectory.appending(path: "workspace", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        terminateLeftoverServer()

        let password = Self.randomPassword()
        var environment = ProcessInfo.processInfo.environment
        if let shellPath { environment["PATH"] = shellPath }
        environment["OPENCODE_CONFIG_CONTENT"] = OpenCodeAPI.configContent()
        environment["OPENCODE_SERVER_PASSWORD"] = password
        environment["OPENCODE_DB"] = supportDirectory.appending(path: "sessions.db").path
        environment["OPENCODE_DISABLE_PROJECT_CONFIG"] = "1"
        environment["OPENCODE_DISABLE_CLAUDE_CODE"] = "1"
        environment["OPENCODE_DISABLE_AUTOUPDATE"] = "1"

        let process = Process()
        process.executableURL = executable
        process.arguments = ["serve", "--hostname", "127.0.0.1", "--port", "0"]
        process.environment = environment
        process.currentDirectoryURL = workspace
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let reader = LaunchOutputReader()
        // Keep draining after startup so a full pipe never blocks the server.
        output.fileHandleForReading.readabilityHandler = { handle in reader.append(handle.availableData) }
        process.terminationHandler = { [weak self] ended in
            output.fileHandleForReading.readabilityHandler = nil
            reader.finish()
            Task { @MainActor in self?.processEnded(ended) }
        }
        try process.run()
        self.process = process
        try? String(process.processIdentifier).write(to: pidFile, atomically: true, encoding: .utf8)

        guard let url = await reader.waitForURL(timeout: 20) else {
            Self.terminateTree(process.processIdentifier)
            let detail = reader.tail.trimmingCharacters(in: .whitespacesAndNewlines)
            throw TextAssistantError.openCodeUnavailable(detail.isEmpty ? "it didn’t start within 20 seconds" : String(detail.suffix(200)))
        }
        let token = Data("opencode:\(password)".utf8).base64EncodedString()
        return Connection(baseURL: url, authorization: "Basic \(token)")
    }

    private func processEnded(_ ended: Process) {
        guard ended === process else { return }
        process = nil
        connection = nil
        if state == .running { state = .stopped }
    }

    /// A server left by a Mac Tools that quit unexpectedly is stopped before starting another.
    private func terminateLeftoverServer() {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return }
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        // Only a process that is still an opencode binary (Homebrew's is opencode.exe);
        // the PID may have been reused.
        let name = URL(fileURLWithPath: String(decoding: buffer.prefix(Int(max(length, 0))), as: UTF8.self)).lastPathComponent
        if length > 0, name == "opencode" || name == "opencode.exe" {
            Self.terminateTree(pid)
        }
        try? FileManager.default.removeItem(at: pidFile)
    }

    /// Some installs start OpenCode through a Node launcher that runs the
    /// real server as a child, so stop children before the process itself.
    private static func terminateTree(_ pid: pid_t) {
        var children = [pid_t](repeating: 0, count: 64)
        let count = proc_listchildpids(pid, &children, Int32(children.count * MemoryLayout<pid_t>.size))
        for child in children.prefix(Int(max(count, 0))) where child > 0 { kill(child, SIGTERM) }
        kill(pid, SIGTERM)
    }

    private static func randomPassword() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Models and sign-in

    /// Reloads the signed-in providers' models. `restart` picks up new sign-ins.
    func refreshModels(restart: Bool = false) async {
        if restart { stop() }
        isLoadingModels = true
        defer { isLoadingModels = false }
        do {
            let connection = try await connect()
            var request = URLRequest(url: connection.baseURL.appending(path: "provider"), timeoutInterval: 20)
            request.setValue(connection.authorization, forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw TextAssistantError.openCodeUnavailable("it couldn’t list its providers")
            }
            modelGroups = try OpenCodeAPI.modelGroups(from: data)
            modelsError = modelGroups.isEmpty ? "OpenCode isn’t signed in to any provider yet." : nil
        } catch {
            modelsError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// The server plus the provider and model to use for a request.
    func prepare(modelKey: String) async throws -> (Connection, providerID: String, modelID: String) {
        let connection = try await connect()
        if modelGroups.isEmpty { await refreshModels() }
        let key = modelKey.isEmpty ? (modelGroups.preferredDefault(OpenCodeAPI.preferredModels)?.id ?? "") : modelKey
        guard let parts = ModelOption.split(key) else {
            throw modelGroups.isEmpty ? TextAssistantError.openCodeNotSignedIn(provider: "any provider") : TextAssistantError.noModelSelected
        }
        if !modelGroups.isEmpty, !modelGroups.contains(where: { $0.id == parts.providerID }) {
            throw TextAssistantError.openCodeNotSignedIn(provider: parts.providerID)
        }
        return (connection, parts.providerID, parts.modelID)
    }

    /// Opens Terminal with `opencode auth login`, OpenCode's own provider sign-in.
    func openSignIn() {
        guard let executable = executable ?? nil else { return }
        let script = FileManager.default.temporaryDirectory.appending(path: "Mac Tools – OpenCode Sign In.command")
        let quoted = "'" + executable.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let contents = """
        #!/bin/zsh
        clear
        echo "Sign in to a provider for OpenCode. Mac Tools Text Assistant uses the same sign-ins."
        echo
        \(quoted) auth login
        echo
        echo "Done. Return to Mac Tools Settings and click Refresh."
        """
        do {
            try contents.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            NSWorkspace.shared.open(script)
        } catch {
            modelsError = error.localizedDescription
        }
    }

    // MARK: Helpers

    /// Runs a short command and returns its output, or nil on failure or timeout.
    nonisolated private static func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            let once = ResumeOnce(continuation)
            process.terminationHandler = { ended in
                let data = output.fileHandleForReading.readDataToEndOfFile()
                once.resume(ended.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil)
            }
            do { try process.run() } catch { once.resume(nil); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning { process.terminate() }
                once.resume(nil)
            }
        }
    }
}

/// Collects the server's startup output and reports the address it listens on.
private final class LaunchOutputReader: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    private var url: URL?
    private var finished = false
    private var waiter: CheckedContinuation<URL?, Never>?

    var tail: String { lock.withLock { String(text.suffix(400)) } }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        let resume: (CheckedContinuation<URL?, Never>, URL)? = lock.withLock {
            guard url == nil else { return nil }
            text += String(decoding: data, as: UTF8.self)
            if text.count > 8_000 { text = String(text.suffix(4_000)) }
            guard let found = OpenCodeAPI.listeningURL(in: text) else { return nil }
            url = found
            defer { waiter = nil }
            return waiter.map { ($0, found) }
        }
        resume.map { $0.0.resume(returning: $0.1) }
    }

    func finish() {
        let waiter: CheckedContinuation<URL?, Never>? = lock.withLock {
            finished = true
            defer { self.waiter = nil }
            return self.waiter
        }
        waiter?.resume(returning: nil)
    }

    func waitForURL(timeout: TimeInterval) async -> URL? {
        await withCheckedContinuation { continuation in
            let immediate: URL?? = lock.withLock {
                if let url { return .some(url) }
                if finished { return .some(nil) }
                waiter = continuation
                return nil
            }
            if let immediate { continuation.resume(returning: immediate); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                let pending: CheckedContinuation<URL?, Never>? = self.lock.withLock {
                    defer { self.waiter = nil }
                    return self.waiter
                }
                pending?.resume(returning: nil)
            }
        }
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String?, Never>?

    init(_ continuation: CheckedContinuation<String?, Never>) { self.continuation = continuation }

    func resume(_ value: String?) {
        let pending: CheckedContinuation<String?, Never>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}
