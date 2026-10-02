import AppKit
import ApplicationServices
import Combine
import MacToolsCore

/// Gathers every shortcut source into one catalog. Reading happens off the main thread.
@MainActor
final class ShortcutsStore: ObservableObject {
    @Published private(set) var catalog: ShortcutCatalog = .empty
    @Published private(set) var capturedApps: [String: CapturedApp] = [:]
    @Published private(set) var isScanning = false
    @Published private(set) var lastScan: Date?
    /// False until settings have been read once; until then the catalog is empty, not "all free".
    @Published private(set) var hasLoaded = false
    /// "Reading Cursor's menus…" while a scan runs.
    @Published private(set) var progress: String?

    typealias AppLocator = @Sendable (String) -> URL?

    private let cache: MenuShortcutCacheStore
    private let preferencesDirectory: URL
    private let appLocator: AppLocator
    private let runningApplications: @MainActor () -> [RunningApp]
    private let macToolsShortcuts: @MainActor () -> [ShortcutEntry]
    private var settingsEntries: [ShortcutEntry] = []
    private var runningBundleIDs: Set<String> = []
    private var scanTask: Task<Void, Never>?

    init(
        cache: MenuShortcutCacheStore = MenuShortcutCacheStore(),
        preferencesDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences"),
        appLocator: @escaping AppLocator = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
        runningApplications: @escaping @MainActor () -> [RunningApp] = {
            NSWorkspace.shared.runningApplications.compactMap(RunningApp.init)
        },
        macToolsShortcuts: @escaping @MainActor () -> [ShortcutEntry]
    ) {
        self.cache = cache
        self.preferencesDirectory = preferencesDirectory
        self.appLocator = appLocator
        self.runningApplications = runningApplications
        self.macToolsShortcuts = macToolsShortcuts
        capturedApps = cache.load()
    }

    /// Re-reads every source; with `captureMenus`, also reads the menus of running apps.
    func refresh(captureMenus: Bool) async {
        if let scanTask {
            await scanTask.value
            return
        }
        let task = Task { await performRefresh(captureMenus: captureMenus) }
        scanTask = task
        await task.value
        scanTask = nil
    }

    private func performRefresh(captureMenus: Bool) async {
        isScanning = true
        progress = "Reading settings…"
        defer {
            isScanning = false
            progress = nil
            lastScan = Date()
        }

        let running = runningApplications()
        // Menu-bar apps (no Dock icon) count as running: their global shortcuts are live.
        runningBundleIDs = Set(running.map(\.bundleID))
        let directory = preferencesDirectory
        let locator = appLocator
        let runningIDs = runningBundleIDs
        settingsEntries = await Task.detached(priority: .userInitiated) {
            SettingsShortcutReader.entries(preferencesDirectory: directory, appLocator: locator, running: runningIDs)
        }.value

        let appLocator = self.appLocator
        capturedApps = capturedApps.filter { appLocator($0.key) != nil }
        rebuild()
        hasLoaded = true

        guard captureMenus, AXIsProcessTrusted() else { return }
        for app in running where app.isRegular {
            progress = "Reading \(app.name)’s menus…"
            if let captured = await Self.captureOffMain(app) {
                capturedApps[app.bundleID] = captured
                rebuild()
            }
        }
        try? cache.save(capturedApps)
    }

    /// Reads one app's menus, e.g. right after it launches.
    func capture(app: NSRunningApplication) async {
        guard AXIsProcessTrusted(), let target = RunningApp(app), target.isRegular, let captured = await Self.captureOffMain(target) else { return }
        capturedApps[target.bundleID] = captured
        runningBundleIDs.insert(target.bundleID)
        rebuild()
        try? cache.save(capturedApps)
    }

    func forgetCapturedMenus() {
        cache.forget()
        capturedApps = [:]
        rebuild()
    }

    /// Mac Tools' own shortcuts can change at any time; rebuild without re-reading anything else.
    func refreshMacToolsShortcuts() {
        rebuild()
    }

    private func rebuild() {
        let menus = capturedApps.values.flatMap { $0.entries(isRunning: runningBundleIDs.contains($0.bundleID)) }
        catalog = ShortcutCatalog(entries: settingsEntries + macToolsShortcuts() + menus)
    }

    // MARK: Running apps

    struct RunningApp: Sendable {
        let pid: pid_t
        let bundleID: String
        let name: String
        /// Has a Dock icon and menu bar; only these have menus worth reading.
        let isRegular: Bool

        init(pid: pid_t, bundleID: String, name: String, isRegular: Bool) {
            self.pid = pid
            self.bundleID = bundleID
            self.name = name
            self.isRegular = isRegular
        }

        init?(_ app: NSRunningApplication) {
            guard !app.isTerminated, let bundleID = app.bundleIdentifier, bundleID != Bundle.main.bundleIdentifier
            else { return nil }
            self.init(
                pid: app.processIdentifier, bundleID: bundleID, name: app.localizedName ?? bundleID,
                isRegular: app.activationPolicy == .regular
            )
        }
    }

    private static func captureOffMain(_ app: RunningApp) async -> CapturedApp? {
        await Task.detached(priority: .utility) {
            MenuShortcutReader.capture(pid: app.pid, bundleID: app.bundleID, name: app.name)
        }.value
    }
}

/// Global and settings-based sources, read from preference files.
enum SettingsShortcutReader {
    private static let maxFileSize = 5_000_000

    static func entries(preferencesDirectory: URL, appLocator: (String) -> URL?, running: Set<String>) -> [ShortcutEntry] {
        var entries = MacOSShortcuts.fixed + MacOSShortcuts.standard
        let symbolic = plist(preferencesDirectory.appendingPathComponent("com.apple.symbolichotkeys.plist"))
        entries += MacOSShortcuts.entries(symbolicHotKeys: symbolic?["AppleSymbolicHotKeys"] as? [String: Any] ?? [:])

        let global = plist(preferencesDirectory.appendingPathComponent(".GlobalPreferences.plist"))
        let allApps = ShortcutSource(id: "all-apps", name: "All Apps", kind: .system)
        entries += PreferenceShortcutScanner.userKeyEquivalents(global?["NSUserKeyEquivalents"], source: allApps)

        if appLocator(RectangleShortcuts.bundleID) != nil {
            let preferences = plist(preferencesDirectory.appendingPathComponent("\(RectangleShortcuts.bundleID).plist")) ?? [:]
            entries += RectangleShortcuts.entries(preferences: preferences, isRunning: running.contains(RectangleShortcuts.bundleID))
        }

        let skipped: Set<String> = [RectangleShortcuts.bundleID, Bundle.main.bundleIdentifier ?? "", "com.local.MacTools"]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: preferencesDirectory, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
        )) ?? []
        for file in files where file.pathExtension == "plist" {
            let bundleID = file.deletingPathExtension().lastPathComponent
            guard !skipped.contains(bundleID), !bundleID.hasPrefix("com.apple."),
                  let appURL = appLocator(bundleID), let preferences = plist(file)
            else { continue }
            let name = appURL.deletingPathExtension().lastPathComponent
            let source = ShortcutSource.app(bundleID: bundleID, name: name)
            entries += PreferenceShortcutScanner.entries(
                bundleID: bundleID, appName: name, preferences: preferences, isRunning: running.contains(bundleID)
            )
            entries += PreferenceShortcutScanner.userKeyEquivalents(preferences["NSUserKeyEquivalents"], source: source)
        }
        return entries
    }

    private static func plist(_ url: URL) -> [String: Any]? {
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maxFileSize { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}
