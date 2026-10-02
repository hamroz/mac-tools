import AppKit
import Foundation

/// Finding and running the command-line tools Text Assistant uses (OpenCode,
/// Claude Code). Mac Tools starts from Finder with a minimal PATH, so tools are
/// found the way the user's login shell finds them.
enum ShellCommand {
    struct Result: Sendable {
        let status: Int32
        let output: String
        let errors: String
    }

    /// Each name's path as the login shell resolves it, plus that shell's PATH.
    static func loginShellLookup(_ names: [String]) async -> (paths: [String: String], path: String?) {
        let marker = "__MACTOOLS__"
        let lookups = names.map { "echo \(marker)\($0)=$(command -v \($0))" }.joined(separator: "; ")
        let script = lookups + "; echo \(marker)PATH=$PATH"
        guard let result = await run(URL(fileURLWithPath: "/bin/zsh"), ["-lic", script], timeout: 8) else { return ([:], nil) }
        var paths: [String: String] = [:], path: String?
        for line in result.output.components(separatedBy: "\n") where line.hasPrefix(marker) {
            let entry = line.dropFirst(marker.count)
            guard let equals = entry.firstIndex(of: "=") else { continue }
            let key = String(entry[..<equals]), value = String(entry[entry.index(after: equals)...])
            if key == "PATH" { path = value } else if value.hasPrefix("/") { paths[key] = value }
        }
        return (paths, path)
    }

    /// The login shell's choice first, so the copy the user runs in Terminal wins
    /// over an older one elsewhere, then the usual install locations.
    static func locate(_ name: String, candidates: [String]) async -> (url: URL?, path: String?) {
        let shell = await loginShellLookup([name])
        let found = shell.paths[name].flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
            ?? candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        return (found.map { URL(fileURLWithPath: $0) }, shell.path)
    }

    /// Runs a command to completion. nil when it can't start or exceeds `timeout`;
    /// cancelling the calling task stops the command.
    static func run(
        _ executable: URL, _ arguments: [String],
        environment: [String: String]? = nil, input: Data? = nil,
        currentDirectory: URL? = nil, timeout: TimeInterval
    ) async -> Result? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        let output = Pipe(), errors = Pipe(), stdin = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        let collected = OutputCollector()
        output.fileHandleForReading.readabilityHandler = { collected.appendOutput($0.availableData) }
        errors.fileHandleForReading.readabilityHandler = { collected.appendErrors($0.availableData) }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Result?, Never>) in
                let once = ResumeOnce(continuation)
                process.terminationHandler = { ended in
                    output.fileHandleForReading.readabilityHandler = nil
                    errors.fileHandleForReading.readabilityHandler = nil
                    collected.appendOutput(output.fileHandleForReading.readDataToEndOfFile())
                    collected.appendErrors(errors.fileHandleForReading.readDataToEndOfFile())
                    once.resume(collected.result(status: ended.terminationStatus))
                }
                do { try process.run() } catch { once.resume(nil); return }
                if let input {
                    stdin.fileHandleForWriting.write(input)
                    try? stdin.fileHandleForWriting.close()
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    guard process.isRunning else { return }
                    process.terminate()
                    once.resume(nil)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    /// Opens Terminal running `command`, e.g. a tool's own sign-in.
    @MainActor
    static func openInTerminal(title: String, intro: String, command: String, outro: String) throws {
        let script = FileManager.default.temporaryDirectory.appending(path: "Mac Tools – \(title).command")
        let contents = """
        #!/bin/zsh -l
        clear
        echo \(quoted(intro))
        echo
        \(command)
        echo
        echo \(quoted(outro))
        """
        try contents.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        NSWorkspace.shared.open(script)
    }

    static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var output = Data()
    private var errors = Data()

    func appendOutput(_ data: Data) { lock.withLock { output.append(data) } }
    func appendErrors(_ data: Data) { lock.withLock { errors.append(data) } }

    func result(status: Int32) -> ShellCommand.Result {
        lock.withLock {
            ShellCommand.Result(status: status, output: String(decoding: output, as: UTF8.self),
                                errors: String(decoding: errors, as: UTF8.self))
        }
    }
}

final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) { self.continuation = continuation }

    func resume(_ value: Value) {
        let pending: CheckedContinuation<Value, Never>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}
