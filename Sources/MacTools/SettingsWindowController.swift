import AppKit
import MacToolsCore
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    init(hotKeyManager: HotKeyManager, launchAtLoginManager: LaunchAtLoginManager, workspaceSettings: WorkspaceSettings,
         overviewMonitor: DockOverviewMonitor) {
        let rootView = StickiesSettingsView(
            hotKeyManager: hotKeyManager,
            launchAtLoginManager: launchAtLoginManager,
            workspaceSettings: workspaceSettings,
            overviewMonitor: overviewMonitor
        )
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 500, height: 700),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Mac Tools Settings"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: rootView)
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        launchManager?.refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private var launchManager: LaunchAtLoginManager? {
        (window?.contentViewController as? NSHostingController<StickiesSettingsView>)?.rootView.launchAtLoginManager
    }
}

struct StickiesSettingsView: View {
    @ObservedObject var hotKeyManager: HotKeyManager
    @ObservedObject var launchAtLoginManager: LaunchAtLoginManager
    @ObservedObject var workspaceSettings: WorkspaceSettings
    @ObservedObject var overviewMonitor: DockOverviewMonitor

    var body: some View {
        Form {
            Section("Show Desktop") {
                Text("Keep notes pinned and editable when using Command–F3 or your Show Desktop hot corner.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("Requires Accessibility access to observe Dock’s desktop modes. These undocumented notifications may change with macOS updates.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Enable Accessibility…") { overviewMonitor.requestPermission() }
                    Button("Recheck") { overviewMonitor.retry() }
                }
                Text(overviewMonitor.status)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Text("After each launch, enter and exit Show Desktop once to synchronize. Notes may briefly appear while Mission Control opens; this is a known limitation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Workspaces") {
                Picker("Show notes", selection: workspaceBinding) {
                    ForEach(NoteWorkspaceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)

                Text(workspaceSettings.mode.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Applies to all existing and new notes. Notes are hidden in Mission Control in either mode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Desktop Stickies") {
                LabeledContent("New Note shortcut") {
                    Picker("Shortcut", selection: hotKeyBinding) {
                        ForEach(HotKeyPreset.allCases) { preset in
                            Text(preset.displayName).tag(preset)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }

                if let error = hotKeyManager.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Startup") {
                Toggle("Launch Mac Tools at login", isOn: launchBinding)

                HStack {
                    Text(launchAtLoginManager.state.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if launchAtLoginManager.state == .requiresApproval {
                        Button("Open Login Items") {
                            launchAtLoginManager.openSystemSettings()
                        }
                    }
                }

                if let error = launchAtLoginManager.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Text("Notes are stored only on this Mac. Mac Tools does not use accounts, analytics, or network access.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(8)
        .frame(width: 500, height: 700)
    }

    private var workspaceBinding: Binding<NoteWorkspaceMode> {
        Binding(get: { workspaceSettings.mode }, set: { workspaceSettings.setMode($0) })
    }

    private var hotKeyBinding: Binding<HotKeyPreset> {
        Binding(
            get: { hotKeyManager.preset },
            set: { hotKeyManager.setPreset($0) }
        )
    }

    private var launchBinding: Binding<Bool> {
        Binding(
            get: { launchAtLoginManager.isEnabled },
            set: { launchAtLoginManager.setEnabled($0) }
        )
    }
}
