import KeyboardShortcuts
import MacToolsCore
import SwiftUI

/// Shortcuts' page in Mac Tools Settings. Returns form sections only.
struct ShortcutsSettingsView: View {
    @ObservedObject var settings: ShortcutsSettings
    @ObservedObject var store: ShortcutsStore
    @ObservedObject var permission: AccessibilityPermission
    let openWindow: () -> Void

    var body: some View {
        Section {
            LabeledContent("Open the Shortcuts window") {
                KeyboardShortcuts.Recorder(for: .shortcutsShowWindow)
            }
            LabeledContent("Browse and check") {
                Button("Show Shortcuts…", action: openWindow)
            }
        } header: {
            Text("Shortcuts Window")
        } footer: {
            Text("No shortcut is set until you record one. Show Shortcuts and Check a Shortcut are also in the Mac Tools menu.")
                .settingsFootnote()
        }

        Section {
            Toggle("Read an app’s menus when it opens", isOn: $settings.captureMenusAutomatically)
            LabeledContent("Accessibility") {
                if permission.isTrusted {
                    Label("Allowed", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    HStack {
                        Button("Allow…") { permission.request() }
                        Button("Open System Settings") { permission.openSystemSettings() }
                    }
                }
            }
            LabeledContent("Apps read") {
                HStack {
                    Text("\(store.capturedApps.count)").monospacedDigit().foregroundStyle(.secondary)
                    Button("Forget Captured Menus") { store.forgetCapturedMenus() }
                        .disabled(store.capturedApps.isEmpty)
                }
            }
        } header: {
            Text("App Menus")
        } footer: {
            Text("In-app shortcuts come from the menus of running apps, read through Accessibility when you open the Shortcuts window, press Rescan, or (with the option on) when an app opens. They are kept on this Mac only, in ~/Library/Application Support/Mac Tools/Shortcuts/, so apps that aren’t running still show.")
                .settingsFootnote()
        }

        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("**macOS**: the shortcuts in System Settings → Keyboard → Keyboard Shortcuts, including ones you turned off, plus fixed ones like ⌘Tab and ⌥⌘Esc.")
                Text("**Apps**: global shortcuts saved in an app’s settings in the common formats (including Rectangle’s defaults), and your App Shortcuts from System Settings.")
                Text("**Not included**: apps that read keys at a lower level (Karabiner-Elements, BetterTouchTool, Keyboard Maestro), shortcuts saved in an app’s own format, and settings of App Store apps kept in their sandbox. So “free” means free among the shortcuts Mac Tools can see.")
                Text("Shortcuts is read-only: it never changes another app’s settings.")
            }
            .settingsFootnote()
        } header: {
            Text("What It Can See")
        }
        .onAppear { permission.refresh() }
    }
}
