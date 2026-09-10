import AppKit
import MacToolsCore
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    init(hotKeyManager: HotKeyManager, launchAtLoginManager: LaunchAtLoginManager) {
        let rootView = StickiesSettingsView(
            hotKeyManager: hotKeyManager,
            launchAtLoginManager: launchAtLoginManager
        )
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 480, height: 300),
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

    var body: some View {
        Form {
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
        .frame(width: 480, height: 300)
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
