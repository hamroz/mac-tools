import AppKit
import MacToolsCore
import SwiftUI

enum ShortcutsPage: Hashable {
    case check
    case allGlobal
    case conflicts
    /// Global shortcuts of one source (`ShortcutSource.id`).
    case source(String)
    case standard
    /// In-app shortcuts of one source (`ShortcutSource.id`).
    case app(String)
}

@MainActor
final class ShortcutsNavigation: ObservableObject {
    @Published var page: ShortcutsPage? = .allGlobal
}

@MainActor
final class ShortcutsWindowController: NSWindowController {
    private let navigation = ShortcutsNavigation()
    private let store: ShortcutsStore
    /// Scans more often than this only when asked with Rescan.
    private static let freshness: TimeInterval = 60

    init(store: ShortcutsStore, pauseHotKeys: @escaping (Bool) -> Void) {
        self.store = store
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Shortcuts"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.minSize = CGSize(width: 720, height: 460)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("MacToolsShortcuts")
        let hosting = NSHostingController(rootView: ShortcutsRootView(
            store: store, navigation: navigation, permission: .shared, pauseHotKeys: pauseHotKeys
        ))
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(CGSize(width: 900, height: 600))
        if !window.setFrameUsingName("MacToolsShortcuts") { window.center() }
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(_ page: ShortcutsPage) {
        navigation.page = page
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        store.refreshMacToolsShortcuts()
        if let last = store.lastScan, Date().timeIntervalSince(last) < Self.freshness { return }
        Task { await store.refresh(captureMenus: true) }
    }
}

// MARK: - Root

struct ShortcutsRootView: View {
    @ObservedObject var store: ShortcutsStore
    @ObservedObject var navigation: ShortcutsNavigation
    @ObservedObject var permission: AccessibilityPermission
    let pauseHotKeys: (Bool) -> Void
    @State private var search = ""

    private var catalog: ShortcutCatalog { store.catalog }

    var body: some View {
        NavigationSplitView {
            List(selection: $navigation.page) {
                Section {
                    SidebarLabel(title: "Check a Shortcut", symbol: "checkmark.seal", tint: .green)
                        .tag(ShortcutsPage.check)
                }
                Section("Global") {
                    SidebarLabel(title: "All Global", symbol: "globe", tint: .blue, count: catalog.globalEntries.count)
                        .tag(ShortcutsPage.allGlobal)
                    SidebarLabel(
                        title: "Conflicts", symbol: "exclamationmark.triangle", tint: catalog.conflicts.isEmpty ? .secondary : .orange,
                        count: catalog.conflicts.count
                    )
                    .tag(ShortcutsPage.conflicts)
                    ForEach(globalSources) { source in
                        SidebarLabel(
                            title: source.name, symbol: symbol(for: source), tint: .secondary,
                            count: catalog.globalEntries.filter { $0.source.id == source.id }.count,
                            subtitle: isRunning(source) ? nil : "Not running"
                        )
                        .tag(ShortcutsPage.source(source.id))
                    }
                }
                Section("In-App") {
                    SidebarLabel(title: "Standard", symbol: "command", tint: .secondary, count: MacOSShortcuts.standard.count)
                        .tag(ShortcutsPage.standard)
                    ForEach(inAppSources) { source in
                        SidebarLabel(
                            title: source.name, symbol: "macwindow", tint: .secondary,
                            count: catalog.inAppEntries.filter { $0.source.id == source.id }.count,
                            subtitle: capturedSubtitle(source)
                        )
                        .tag(ShortcutsPage.app(source.id))
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .toolbar { toolbar }
        }
        .frame(minWidth: 720, minHeight: 460)
    }

    @ViewBuilder
    private var detail: some View {
        switch navigation.page ?? .allGlobal {
        case .check:
            ShortcutCheckView(store: store, pauseHotKeys: pauseHotKeys)
        case .allGlobal:
            list("All Global Shortcuts", "Shortcuts that work whichever app is in front.", catalog.globalEntries, groupBySource: true)
        case .conflicts:
            list(
                "Conflicts", "Two or more global shortcuts use the same keys. Usually only one of them works.",
                catalog.conflicts.values.flatMap { $0 }, groupByCombo: true, empty: "No conflicts found"
            )
        case .source(let id):
            let entries = catalog.globalEntries.filter { $0.source.id == id }
            list(entries.first?.source.name ?? "Global", sourceSubtitle(entries.first?.source), entries)
        case .standard:
            list("Standard Shortcuts", "Shortcuts nearly every app uses. A global shortcut on one of these breaks it everywhere.", MacOSShortcuts.standard)
        case .app(let id):
            let entries = catalog.inAppEntries.filter { $0.source.id == id }
            list(entries.first?.source.name ?? "App", appSubtitle(id), entries, needsAccessibility: true)
        }
    }

    private func list(
        _ title: String, _ subtitle: String, _ entries: [ShortcutEntry],
        groupBySource: Bool = false, groupByCombo: Bool = false, empty: String = "No shortcuts", needsAccessibility: Bool = false
    ) -> some View {
        ShortcutListView(
            title: title, subtitle: subtitle, entries: catalog.entries(matching: search, in: entries), catalog: catalog,
            grouping: groupByCombo ? .combo : groupBySource ? .source : .detail, emptyTitle: search.isEmpty ? empty : "No matches",
            showsAccessibilityPrompt: needsAccessibility && !permission.isTrusted, permission: permission
        )
        .searchable(text: $search, placement: .toolbar, prompt: "Search actions, apps, or keys")
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            HStack(spacing: 8) {
                if store.isScanning {
                    ProgressView().controlSize(.small)
                    Text(store.progress ?? "Scanning…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Button {
                    Task { await store.refresh(captureMenus: true) }
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .help("Read every source again, including the menus of running apps")
                .disabled(store.isScanning)
            }
        }
    }

    // MARK: Sidebar data

    private var globalSources: [ShortcutSource] {
        let sources = Dictionary(grouping: catalog.globalEntries, by: \.source.id).compactMap { $0.value.first?.source }
        return sources.sorted { lhs, rhs in
            let order: (ShortcutSource) -> Int = { $0 == .macOS ? 0 : $0 == .macTools ? 1 : 2 }
            if order(lhs) != order(rhs) { return order(lhs) < order(rhs) }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private var inAppSources: [ShortcutSource] {
        Dictionary(grouping: catalog.inAppEntries.filter { $0.source != .standard }, by: \.source.id)
            .compactMap { $0.value.first?.source }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func isRunning(_ source: ShortcutSource) -> Bool {
        catalog.globalEntries.first { $0.source.id == source.id }?.isSourceRunning ?? true
    }

    private func symbol(for source: ShortcutSource) -> String {
        switch source.kind {
        case .system: "apple.logo"
        case .macTools: "square.stack.3d.up.fill"
        case .standard: "command"
        case .app: "app"
        }
    }

    private func capturedSubtitle(_ source: ShortcutSource) -> String? {
        guard let captured = store.capturedApps[source.id]?.capturedAt else { return nil }
        return "Read " + captured.formatted(.relative(presentation: .named))
    }

    private func sourceSubtitle(_ source: ShortcutSource?) -> String {
        switch source?.kind {
        case .system: return "macOS’s own shortcuts, including ones you turned off in System Settings → Keyboard → Keyboard Shortcuts."
        case .macTools: return "Shortcuts of the Mac Tools tools that are turned on."
        case .app: return isRunning(source!) ? "Found in this app’s settings." : "Found in this app’s settings. They work only while the app is running."
        default: return ""
        }
    }

    private func appSubtitle(_ id: String) -> String {
        if let captured = store.capturedApps[id] {
            return "From the app’s menus, read \(captured.capturedAt.formatted(.relative(presentation: .named)))."
        }
        return "Shortcuts you added in System Settings → Keyboard → App Shortcuts."
    }
}

private struct SidebarLabel: View {
    let title: String
    let symbol: String
    let tint: Color
    var count: Int?
    var subtitle: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let count {
                Text("\(count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - List

struct ShortcutListView: View {
    enum Grouping { case detail, source, combo }

    let title: String
    let subtitle: String
    let entries: [ShortcutEntry]
    let catalog: ShortcutCatalog
    let grouping: Grouping
    let emptyTitle: String
    let showsAccessibilityPrompt: Bool
    @ObservedObject var permission: AccessibilityPermission

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.title2.weight(.semibold))
                        Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 6)
                    if showsAccessibilityPrompt {
                        AccessibilityPrompt(permission: permission)
                    }
                }
                ForEach(groups, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.entries) { entry in
                            ShortcutRow(
                                entry: entry, clashes: catalog.clashes(with: entry),
                                showsSource: grouping == .combo, showsDetail: grouping == .source
                            )
                        }
                    }
                }
            }
            .overlay {
                if entries.isEmpty {
                    ContentUnavailableView(emptyTitle, systemImage: "keyboard")
                }
            }
            Divider()
            Text("Free means free among the shortcuts Mac Tools can see. Apps that read keys at a lower level, like Karabiner-Elements, BetterTouchTool, or Keyboard Maestro, or that save shortcuts in their own format, aren’t included.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
    }

    private var groups: [(title: String, entries: [ShortcutEntry])] {
        Self.group(entries, by: grouping)
    }

    /// Sections for the list: macOS and Mac Tools first when grouped by source; inside a section,
    /// shortcuts that are on come first, ordered by area, then keys.
    static func group(_ entries: [ShortcutEntry], by grouping: Grouping) -> [(title: String, entries: [ShortcutEntry])] {
        let key: (ShortcutEntry) -> String = switch grouping {
        case .detail: { $0.detail ?? "" }
        case .source: { $0.source.name }
        case .combo: { $0.combo.displayString }
        }
        let sourceOrder: (String) -> Int = { $0 == ShortcutSource.macOS.name ? 0 : $0 == ShortcutSource.macTools.name ? 1 : 2 }
        return Dictionary(grouping: entries, by: key)
            .map { title, entries in
                (title, entries.sorted { lhs, rhs in
                    if lhs.isEnabled != rhs.isEnabled { return lhs.isEnabled }
                    let lhsDetail = lhs.detail ?? "", rhsDetail = rhs.detail ?? ""
                    if lhsDetail != rhsDetail { return lhsDetail.localizedCaseInsensitiveCompare(rhsDetail) == .orderedAscending }
                    if lhs.combo != rhs.combo { return lhs.combo < rhs.combo }
                    return (lhs.source.name, lhs.action) < (rhs.source.name, rhs.action)
                })
            }
            .sorted { lhs, rhs in
                if grouping == .source, sourceOrder(lhs.title) != sourceOrder(rhs.title) {
                    return sourceOrder(lhs.title) < sourceOrder(rhs.title)
                }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
    }
}

struct ShortcutRow: View {
    let entry: ShortcutEntry
    var clashes: [ShortcutEntry] = []
    var showsSource = false
    var showsDetail = false

    var body: some View {
        HStack(spacing: 12) {
            KeyCaps(combo: entry.combo)
                .frame(width: 110, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.action)
                    .foregroundStyle(entry.isEnabled ? .primary : .secondary)
                if let secondary {
                    Text(secondary).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if !clashes.isEmpty {
                Badge(text: "Clash", symbol: "exclamationmark.triangle.fill", tint: .orange)
                    .help("Also used by " + clashes.map { "\($0.source.name): \($0.action)" }.joined(separator: ", "))
            }
            if !entry.isEnabled { Badge(text: "Off", tint: .secondary) }
            if entry.isProbablyInApp {
                Badge(text: "Probably in-app", tint: .secondary)
                    .help("Found in the app’s settings, but shaped like a menu shortcut, so it isn’t counted as global.")
            }
            if !entry.isSourceRunning, entry.scope == .global {
                Badge(text: "Not running", tint: .secondary)
                    .help("This app’s global shortcuts work only while it’s running.")
            }
        }
        .padding(.vertical, 2)
        .textSelection(.enabled)
    }

    private var secondary: String? {
        if showsSource { return [entry.source.name, entry.detail].compactMap { $0 }.joined(separator: " · ") }
        if showsDetail || (entry.scope == .global && entry.source.kind != .system) { return entry.detail }
        return nil
    }
}

struct KeyCaps: View {
    let combo: KeyCombo
    var large = false

    var body: some View {
        Text(combo.displayString)
            .font(large ? .system(size: 34, weight: .semibold, design: .rounded) : .system(.body, design: .rounded).weight(.medium))
            .monospacedDigit()
            .padding(.horizontal, large ? 14 : 7)
            .padding(.vertical, large ? 6 : 2)
            .background(RoundedRectangle(cornerRadius: large ? 10 : 6, style: .continuous).fill(.quaternary))
            .accessibilityLabel(combo.searchText)
    }
}

struct Badge: View {
    let text: String
    var symbol: String?
    let tint: Color

    var body: some View {
        Label {
            Text(text)
        } icon: {
            if let symbol { Image(systemName: symbol) }
        }
        .labelStyle(BadgeLabelStyle(hasIcon: symbol != nil))
        .font(.caption.weight(.medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().strokeBorder(tint.opacity(0.5)))
    }
}

private struct BadgeLabelStyle: LabelStyle {
    let hasIcon: Bool
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            if hasIcon { configuration.icon }
            configuration.title
        }
    }
}

struct AccessibilityPrompt: View {
    @ObservedObject var permission: AccessibilityPermission

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield").foregroundStyle(.orange)
            Text("Allow Accessibility so Mac Tools can read app menus. Menus read earlier still show.")
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Allow…") { permission.request() }
            Button("Open System Settings") { permission.openSystemSettings() }
        }
        .padding(.vertical, 4)
    }
}
