import AppKit
import Combine
import MacToolsCore

/// config.json (modes, tones, prompts) and my-style.md (writing samples) in
/// ~/Library/Application Support/Mac Tools/Text Assistant. Created with defaults
/// on first run and reloaded when they change; a broken config.json keeps the
/// last good one in use and reports the problem.
@MainActor
final class TextAssistantConfigStore: ObservableObject {
    @Published private(set) var config: TextAssistantConfig
    @Published private(set) var styleSamples: String?
    @Published private(set) var problem: String?
    @Published private(set) var lastLoaded: Date?

    let directory: URL
    var configURL: URL { directory.appending(path: "config.json") }
    var styleURL: URL { directory.appending(path: "my-style.md") }

    private var signature: [Date?] = []
    private var watcher: Task<Void, Never>?

    init(directory: URL = TextAssistantConfigStore.defaultDirectory) {
        self.directory = directory
        config = .defaults
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Mac Tools/Text Assistant", directoryHint: .isDirectory)
    }

    /// Writes any missing file, loads both, and checks for edits every couple of seconds.
    func start(pollInterval: Duration = .seconds(2)) {
        createMissingFiles()
        reload()
        watcher?.cancel()
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: pollInterval) } catch { return }
                self?.reloadIfChanged()
            }
        }
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
    }

    /// Also called right before a run, so an edit saved a moment ago is used.
    func reloadIfChanged() {
        if currentSignature() != signature { reload() }
    }

    func reload() {
        createMissingFiles()
        signature = currentSignature()
        do {
            config = try TextAssistantConfig.decode(Data(contentsOf: configURL))
            problem = nil
        } catch {
            // Keep using the last good config while the file is being fixed.
            problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        let style = (try? String(contentsOf: styleURL, encoding: .utf8)) ?? ""
        styleSamples = StyleSamples.extract(from: style)
        lastLoaded = Date()
    }

    /// Moves a broken or unwanted config.json aside and writes the defaults.
    func restoreDefaultConfig() {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: configURL.path) {
            let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
                .replacingOccurrences(of: ":", with: "-")
            try? fileManager.moveItem(at: configURL, to: directory.appending(path: "config.backup-\(stamp).json"))
        }
        reload()
    }

    func open(_ url: URL) {
        createMissingFiles()
        // JSON often has no default app; fall back to TextEdit rather than doing nothing.
        if NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url)
        } else if let textEdit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            NSWorkspace.shared.open([url], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    func showInFinder() {
        createMissingFiles()
        NSWorkspace.shared.activateFileViewerSelecting([configURL, styleURL])
    }

    private func createMissingFiles() {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: configURL.path) {
            try? TextAssistantConfig.defaults.encoded().write(to: configURL, options: .atomic)
        }
        if !fileManager.fileExists(atPath: styleURL.path) {
            try? Data(TextAssistantConfig.styleTemplate.utf8).write(to: styleURL, options: .atomic)
        }
    }

    private func currentSignature() -> [Date?] {
        [configURL, styleURL].map {
            (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date
        }
    }
}
