import XCTest
import MacToolsCore
@testable import MacTools

/// Talks to the real OpenCode on this Mac and spends a fraction of a cent.
/// Runs only with MACTOOLS_OPENCODE_LIVE=1 (optionally MACTOOLS_OPENCODE_MODEL=provider/model).
@MainActor
final class OpenCodeLiveTests: XCTestCase {
    func test_PrivateServerListsModelsAndRewritesText() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["MACTOOLS_OPENCODE_LIVE"] == "1", "Set MACTOOLS_OPENCODE_LIVE=1 to run")
        let support = FileManager.default.temporaryDirectory.appending(path: "OpenCodeLive-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: support) }
        let server = OpenCodeServer(supportDirectory: support)
        defer { server.stop() }

        await server.locate()
        try XCTSkipUnless(server.isInstalled, "OpenCode isn't installed")
        let started = Date()
        await server.refreshModels()
        print("OpenCode start + model list: \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
        XCTAssertNil(server.modelsError)
        XCTAssertFalse(server.modelGroups.isEmpty)
        print("Signed in to:", server.modelGroups.map { "\($0.name) (\($0.models.count))" }.joined(separator: ", "))

        let provider = OpenCodeProvider(server: server)
        let model = environment["MACTOOLS_OPENCODE_MODEL"] ?? ""
        let request = TextAssistantPrompt.improveRequest(text: "i thinks we shoud meet tommorow", model: model)
        let first = Date()
        let answer = try await provider.complete(request)
        print("Rewrite in \(String(format: "%.2f", Date().timeIntervalSince(first)))s: \(answer)")
        XCTAssertTrue(answer.lowercased().contains("tomorrow"))
        XCTAssertEqual(server.state, .running)
    }
}
