import AppKit
import SwiftUI

enum SettingsPane: Hashable {
    case general
    case tools
    case tool(String)
}

@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var selection: SettingsPane? = .general
}

/// The app-wide Mac Tools Settings window: General, the tool inventory, and
/// one page per registered tool.
@MainActor
final class SettingsWindowController: NSWindowController {
    private let navigation = SettingsNavigation()
    private let launchAtLoginManager: LaunchAtLoginManager

    init(registry: ToolRegistry, launchAtLoginManager: LaunchAtLoginManager) {
        self.launchAtLoginManager = launchAtLoginManager
        let rootView = MacToolsSettingsView(
            registry: registry,
            navigation: navigation,
            launchAtLoginManager: launchAtLoginManager
        )
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Mac Tools Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.minSize = CGSize(width: 680, height: 460)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("MacToolsSettings")
        let hosting = NSHostingController(rootView: rootView)
        // Keep the window's own size; SwiftUI would otherwise shrink it to the minimum.
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(CGSize(width: 760, height: 560))
        if !window.setFrameUsingName("MacToolsSettings") { window.center() }
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(_ pane: SettingsPane? = nil) {
        if let pane { navigation.selection = pane }
        launchAtLoginManager.refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Root

struct MacToolsSettingsView: View {
    @ObservedObject var registry: ToolRegistry
    @ObservedObject var navigation: SettingsNavigation
    @ObservedObject var launchAtLoginManager: LaunchAtLoginManager

    var body: some View {
        NavigationSplitView {
            List(selection: $navigation.selection) {
                Section {
                    SidebarRow(title: "General", symbolName: "gearshape.fill", tint: .gray)
                        .tag(SettingsPane.general)
                    SidebarRow(title: "All Tools", symbolName: "square.grid.2x2.fill", tint: .blue)
                        .tag(SettingsPane.tools)
                }
                Section("Tools") {
                    ForEach(registry.modules, id: \.descriptor.id) { module in
                        SidebarRow(
                            title: module.descriptor.name,
                            symbolName: module.descriptor.symbolName,
                            tint: module.descriptor.tint,
                            isOff: !registry.isEnabled(module.descriptor.id)
                        )
                        .tag(SettingsPane.tool(module.descriptor.id))
                    }
                }
            }
            .frame(minWidth: 220)
            .navigationSplitViewColumnWidth(220)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 680, minHeight: 460)
    }

    @ViewBuilder
    private var detail: some View {
        switch navigation.selection ?? .general {
        case .general:
            GeneralSettingsPane(
                registry: registry,
                launchAtLoginManager: launchAtLoginManager,
                showTools: { navigation.selection = .tools }
            )
        case .tools:
            ToolsOverviewPane(registry: registry, open: { navigation.selection = .tool($0) })
        case .tool(let id):
            if let module = registry.module(id: id) {
                ToolSettingsPane(registry: registry, module: module)
                    .id(id)
            } else {
                ContentUnavailableView("Tool Not Found", systemImage: "questionmark.square.dashed")
            }
        }
    }
}

// MARK: - General

private struct GeneralSettingsPane: View {
    @ObservedObject var registry: ToolRegistry
    @ObservedObject var launchAtLoginManager: LaunchAtLoginManager
    let showTools: () -> Void

    var body: some View {
        Form {
            Section {
                PaneHeader(
                    title: "Mac Tools",
                    subtitle: "A growing collection of small tools for your Mac, living in one menu bar icon.",
                    symbolName: "square.stack.3d.up.fill",
                    tint: .indigo
                ) {
                    Text(Self.version)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Launch Mac Tools at login", isOn: launchBinding)
                if launchAtLoginManager.state == .requiresApproval {
                    LabeledContent("Approval required in System Settings") {
                        Button("Open Login Items") { launchAtLoginManager.openSystemSettings() }
                    }
                }
                if let error = launchAtLoginManager.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Startup")
            } footer: {
                if launchAtLoginManager.state == .unavailable {
                    Text(launchAtLoginManager.state.label).settingsFootnote()
                }
            }

            Section("Tools") {
                LabeledContent("Turned on") {
                    Text("\(registry.enabledIDs.count) of \(registry.modules.count)")
                }
                HStack {
                    Spacer()
                    Button("Manage Tools…", action: showTools)
                }
            }

            Section("Privacy") {
                Label {
                    Text("Mac Tools has no accounts or analytics, and your notes stay on this Mac. Only AI Usage goes online, to read your limits from Anthropic and OpenAI.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "lock.shield.fill").foregroundStyle(.green)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var launchBinding: Binding<Bool> {
        Binding(get: { launchAtLoginManager.isEnabled }, set: { launchAtLoginManager.setEnabled($0) })
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        guard let short = info?["CFBundleShortVersionString"] as? String else { return "Development build" }
        let build = info?["CFBundleVersion"] as? String
        return build.map { "Version \(short) (\($0))" } ?? "Version \(short)"
    }
}

// MARK: - Tool inventory

private struct ToolsOverviewPane: View {
    @ObservedObject var registry: ToolRegistry
    let open: (String) -> Void

    var body: some View {
        Form {
            Section {
                PaneHeader(
                    title: "All Tools",
                    subtitle: "Turn tools on or off. A tool that is off stops running and leaves the menu bar menu; its data stays on this Mac.",
                    symbolName: "square.grid.2x2.fill",
                    tint: .blue
                ) { EmptyView() }
            }

            Section("Installed") {
                ForEach(registry.modules, id: \.descriptor.id) { module in
                    ToolInventoryRow(
                        descriptor: module.descriptor,
                        isOn: enabledBinding(module.descriptor.id),
                        open: { open(module.descriptor.id) }
                    )
                }
            }

            Section {
                HStack(spacing: 12) {
                    ToolIcon(symbolName: "plus", tint: .secondary, size: 28)
                        .opacity(0.5)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("More tools are on the way")
                        Text("New tools will appear here as they are added to Mac Tools.")
                            .settingsFootnote()
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .formStyle(.grouped)
    }

    private func enabledBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { registry.isEnabled(id) }, set: { registry.setEnabled($0, for: id) })
    }
}

private struct ToolInventoryRow: View {
    let descriptor: ToolDescriptor
    @Binding var isOn: Bool
    let open: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: open) {
                HStack(spacing: 12) {
                    ToolIcon(symbolName: descriptor.symbolName, tint: descriptor.tint, size: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(descriptor.name)
                        Text(descriptor.summary)
                            .settingsFootnote()
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open \(descriptor.name) settings")

            Toggle(descriptor.name, isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
            Button(action: open) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(descriptor.name) settings")
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Single tool

private struct ToolSettingsPane: View {
    @ObservedObject var registry: ToolRegistry
    let module: any ToolModule

    var body: some View {
        let descriptor = module.descriptor
        Form {
            Section {
                PaneHeader(
                    title: descriptor.name,
                    subtitle: descriptor.summary,
                    symbolName: descriptor.symbolName,
                    tint: descriptor.tint
                ) {
                    Toggle(descriptor.name, isOn: enabledBinding)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }

            if registry.isEnabled(descriptor.id) {
                module.makeSettingsView()
            } else {
                Section {
                    Text("\(descriptor.name) is off. Turn it on to use it and change its settings.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var enabledBinding: Binding<Bool> {
        let id = module.descriptor.id
        return Binding(get: { registry.isEnabled(id) }, set: { registry.setEnabled($0, for: id) })
    }
}

// MARK: - Components

private struct SidebarRow: View {
    let title: String
    let symbolName: String
    let tint: Color
    var isOff = false

    var body: some View {
        Label {
            HStack {
                Text(title)
                Spacer()
                if isOff {
                    Text("Off")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            ToolIcon(symbolName: symbolName, tint: tint, size: 20)
        }
    }
}

/// A System Settings–style rounded tile holding a white SF Symbol.
struct ToolIcon: View {
    let symbolName: String
    let tint: Color
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(tint.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbolName)
                    .font(.system(size: size * 0.52, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

private struct PaneHeader<Accessory: View>: View {
    let title: String
    let subtitle: String
    let symbolName: String
    let tint: Color
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ToolIcon(symbolName: symbolName, tint: tint, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            accessory
        }
        .padding(.vertical, 4)
    }
}

extension View {
    func settingsFootnote() -> some View {
        font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
