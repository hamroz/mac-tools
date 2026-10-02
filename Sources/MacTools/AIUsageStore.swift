import AppKit
import Combine
import MacToolsCore

@MainActor
final class AIUsageSettings: ObservableObject {
    static let refreshChoices = [1, 2, 5, 15, 30]

    @Published var showInMenuBar: Bool { didSet { defaults.set(showInMenuBar, forKey: Keys.showInMenuBar) } }
    @Published var showPercentInMenuBar: Bool { didSet { defaults.set(showPercentInMenuBar, forKey: Keys.showPercent) } }
    @Published var refreshMinutes: Int { didSet { defaults.set(refreshMinutes, forKey: Keys.refreshMinutes) } }
    @Published private(set) var enabledServices: Set<UsageServiceID>

    private let defaults: UserDefaults

    private enum Keys {
        static let showInMenuBar = "aiUsage.showInMenuBar"
        static let showPercent = "aiUsage.showPercentInMenuBar"
        static let refreshMinutes = "aiUsage.refreshMinutes"
        static func service(_ id: UsageServiceID) -> String { "aiUsage.service.\(id.rawValue).isEnabled" }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showInMenuBar = defaults.object(forKey: Keys.showInMenuBar) as? Bool ?? true
        showPercentInMenuBar = defaults.object(forKey: Keys.showPercent) as? Bool ?? false
        let minutes = defaults.integer(forKey: Keys.refreshMinutes)
        refreshMinutes = Self.refreshChoices.contains(minutes) ? minutes : 5
        enabledServices = Set(UsageServiceID.allCases.filter { defaults.object(forKey: Keys.service($0)) as? Bool ?? true })
    }

    func isEnabled(_ service: UsageServiceID) -> Bool { enabledServices.contains(service) }

    func setEnabled(_ enabled: Bool, for service: UsageServiceID) {
        guard isEnabled(service) != enabled else { return }
        defaults.set(enabled, forKey: Keys.service(service))
        if enabled { enabledServices.insert(service) } else { enabledServices.remove(service) }
    }
}

struct UsageServiceState: Equatable {
    var snapshot: UsageSnapshot?
    /// Set when the latest refresh failed; `snapshot` then still holds the last good numbers.
    var errorMessage: String?
    var isLoading = false
}

@MainActor
final class AIUsageStore: ObservableObject {
    @Published private(set) var states: [UsageServiceID: UsageServiceState] = [:]
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var isRefreshing = false

    let settings: AIUsageSettings
    private let fetchers: [UsageServiceID: any UsageFetching]
    private var schedule: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var observers: [AnyCancellable] = []
    private var wakeObserver: NSObjectProtocol?

    init(settings: AIUsageSettings, fetchers: [UsageServiceID: any UsageFetching] = [
        .claude: ClaudeUsageFetcher(), .codex: CodexUsageFetcher()
    ]) {
        self.settings = settings
        self.fetchers = fetchers
    }

    var activeServices: [UsageServiceID] {
        UsageServiceID.allCases.filter { settings.isEnabled($0) }
    }

    func state(for service: UsageServiceID) -> UsageServiceState {
        states[service] ?? UsageServiceState()
    }

    func start() {
        guard schedule == nil else { return }
        observers = [
            settings.$refreshMinutes.dropFirst().sink { [weak self] _ in self?.reschedule() },
            settings.$enabledServices.dropFirst().removeDuplicates().sink { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            },
        ]
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Give the network a moment to come back after wake.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                self?.refresh()
            }
        }
        reschedule()
    }

    func stop() {
        schedule?.cancel()
        schedule = nil
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshing = false
        observers.removeAll()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
    }

    /// Refreshes when the numbers are older than `maxAge`, e.g. when the popover opens.
    func refreshIfStale(maxAge: TimeInterval = 60) {
        guard let lastRefresh, Date().timeIntervalSince(lastRefresh) < maxAge else { refresh(); return }
    }

    func refresh() {
        guard !isRefreshing else { return }
        let services = activeServices
        isRefreshing = true
        for service in services { states[service, default: UsageServiceState()].isLoading = true }
        refreshTask = Task { [weak self, fetchers] in
            await withTaskGroup(of: (UsageServiceID, Result<UsageSnapshot, Error>).self) { group in
                for service in services {
                    guard let fetcher = fetchers[service] else { continue }
                    group.addTask {
                        do { return (service, .success(try await fetcher.fetch())) }
                        catch { return (service, .failure(error)) }
                    }
                }
                for await (service, result) in group {
                    self?.apply(result, to: service)
                }
            }
            self?.finishRefresh()
        }
    }

    private func apply(_ result: Result<UsageSnapshot, Error>, to service: UsageServiceID) {
        var state = states[service] ?? UsageServiceState()
        state.isLoading = false
        switch result {
        case .success(let snapshot):
            state.snapshot = snapshot
            state.errorMessage = nil
        case .failure(let error):
            state.errorMessage = error.localizedDescription
        }
        states[service] = state
    }

    private func finishRefresh() {
        isRefreshing = false
        lastRefresh = Date()
        refreshTask = nil
    }

    private func reschedule() {
        schedule?.cancel()
        let interval = Duration.seconds(settings.refreshMinutes * 60)
        schedule = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                do { try await Task.sleep(for: interval) } catch { return }
            }
        }
    }
}

extension UsageSnapshot {
    /// Remaining percentage of the window closest to its limit, for compact displays.
    func compactRemaining(at now: Date = Date()) -> Int? {
        guard let window = tightestWindow(at: now) ?? windows.first else { return nil }
        return Int(window.hasReset(at: now) ? 100 : window.remainingPercent.rounded())
    }
}
