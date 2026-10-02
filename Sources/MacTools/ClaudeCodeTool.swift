import Combine
import Foundation
import MacToolsCore

/// The user's Claude Code command-line tool, used with its own sign-in.
@MainActor
final class ClaudeCodeTool: ObservableObject {
    /// nil until located; `.some(nil)` means Claude Code isn't installed.
    @Published private(set) var executable: URL??
    @Published private(set) var version: String?
    @Published private(set) var isSignedIn: Bool?
    @Published private(set) var isChecking = false

    private(set) var shellPath: String?
    let workspace: URL

    init(workspace: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "Mac Tools/Text Assistant/Claude Code", directoryHint: .isDirectory)) {
        self.workspace = workspace
    }

    var isInstalled: Bool { (executable ?? nil) != nil }

    var environment: [String: String] {
        ClaudeCodeCLI.cleanEnvironment(ProcessInfo.processInfo.environment, path: shellPath)
    }

    /// Finds `claude`, its version, and whether it is signed in.
    func refresh() async {
        isChecking = true
        defer { isChecking = false }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let found = await ShellCommand.locate("claude", candidates: [
            "\(home)/.claude/local/claude", "\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
        ])
        shellPath = found.path
        executable = .some(found.url)
        guard let url = found.url else { version = nil; isSignedIn = nil; return }
        version = await ShellCommand.run(url, ["--version"], environment: environment, timeout: 15)?
            .output.split(separator: " ").first.map(String.init)
        let status = await ShellCommand.run(url, ["auth", "status"], environment: environment, timeout: 15)
        isSignedIn = status.map { ClaudeCodeCLI.isSignedIn(authStatusOutput: $0.output) }
    }

    func openSignIn() {
        guard let executable = executable ?? nil else { return }
        try? ShellCommand.openInTerminal(
            title: "Claude Code Sign In",
            intro: "Sign in to Claude Code. Mac Tools Text Assistant uses this sign-in when Claude Code is the model source.",
            command: ShellCommand.quoted(executable.path) + " auth login",
            outro: "Done. Return to Mac Tools Settings and click Refresh."
        )
    }
}

/// Runs `claude -p` once per request. Starting Claude Code takes a few seconds.
struct ClaudeCodeProvider: TextProvider {
    let tool: ClaudeCodeTool
    var timeout: TimeInterval = 60

    func complete(_ request: TextCompletionRequest) async throws -> String {
        let (executable, environment, workspace) = await MainActor.run { (tool.executable, tool.environment, tool.workspace) }
        var claude = executable ?? nil
        if executable == nil {
            await tool.refresh()
            claude = await MainActor.run { tool.executable ?? nil }
        }
        guard let claude else { throw TextAssistantError.claudeCodeNotInstalled }

        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        // The prompt may hold the user's style samples: a private file, removed right after.
        let promptFile = workspace.appending(path: "prompt-\(UUID().uuidString).txt")
        try Data(request.system.utf8).write(to: promptFile, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: promptFile.path)
        defer { try? FileManager.default.removeItem(at: promptFile) }

        let result = await ShellCommand.run(
            claude, ClaudeCodeCLI.arguments(for: request, systemPromptFile: promptFile.path),
            environment: environment, input: Data(request.user.utf8),
            currentDirectory: workspace, timeout: timeout
        )
        try Task.checkCancellation()
        guard let result else { throw TextAssistantError.timedOut }
        return try ClaudeCodeCLI.result(status: result.status, output: result.output, errors: result.errors)
    }
}
