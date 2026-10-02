import MacToolsCore
import SwiftUI

/// AI Usage's page in Mac Tools Settings. Returns form sections only.
struct AIUsageSettingsView: View {
    @ObservedObject var store: AIUsageStore
    @ObservedObject var settings: AIUsageSettings

    var body: some View {
        Section {
            Toggle("Show in menu bar", isOn: $settings.showInMenuBar)
            Toggle("Show percentage left next to the icon", isOn: $settings.showPercentInMenuBar)
                .disabled(!settings.showInMenuBar)
        } header: {
            Text("Menu Bar")
        } footer: {
            Text("The percentage is the lowest amount left across your limits. When the icon is hidden, usage is still in the Mac Tools menu. Command-drag the icon to move it.")
                .settingsFootnote()
        }

        Section("Services") {
            ForEach(UsageServiceID.allCases) { service in
                ServiceSettingsRow(service: service, state: store.state(for: service), isOn: serviceBinding(service))
            }
        }

        Section {
            Picker("Refresh every", selection: $settings.refreshMinutes) {
                ForEach(AIUsageSettings.refreshChoices, id: \.self) { minutes in
                    Text(minutes == 1 ? "1 minute" : "\(minutes) minutes").tag(minutes)
                }
            }
            LabeledContent("Last updated") {
                HStack {
                    if let last = store.lastRefresh {
                        Text(last, format: .dateTime.hour().minute().second())
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Never").foregroundStyle(.secondary)
                    }
                    Button("Refresh Now") { store.refresh() }
                        .disabled(store.isRefreshing)
                }
            }
        } header: {
            Text("Updates")
        } footer: {
            Text("Usage also refreshes when you open the menu bar popup and after your Mac wakes.")
                .settingsFootnote()
        }

        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("**Claude** uses Claude Code’s sign-in from your Keychain to read your limits from Anthropic, the same numbers as Claude Code’s /usage. Claude apps and Claude Code share these limits.")
                Text("**Codex** uses Codex’s sign-in (~/.codex/auth.json) to read your limits from OpenAI, the same numbers as Codex’s /status. If that fails, it shows the limits Codex last recorded on this Mac.")
                Text("Sign-ins are read only when refreshing and are sent only to the service they belong to. Mac Tools never stores or changes them. These usage services aren’t public APIs, so they may change without notice.")
            }
            .settingsFootnote()
        } header: {
            Text("Where the Numbers Come From")
        }
    }

    private func serviceBinding(_ service: UsageServiceID) -> Binding<Bool> {
        Binding(get: { settings.isEnabled(service) }, set: { settings.setEnabled($0, for: service) })
    }
}

private struct ServiceSettingsRow: View {
    let service: UsageServiceID
    let state: UsageServiceState
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            ToolIcon(symbolName: service.symbolName, tint: service.tint, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(service.name)
                Text(status)
                    .settingsFootnote()
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Toggle(service.name, isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    private var status: String {
        guard isOn else { return "\(service.subtitle) · Off" }
        if let error = state.errorMessage, state.snapshot == nil { return error }
        guard let snapshot = state.snapshot else { return service.subtitle }
        let plan = snapshot.plan.map { "\($0) plan" } ?? service.subtitle
        if case .localLog = snapshot.source { return "\(plan) · from Codex’s last session" }
        return "\(plan) · connected"
    }
}
