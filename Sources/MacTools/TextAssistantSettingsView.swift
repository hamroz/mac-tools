import AppKit
import KeyboardShortcuts
import MacToolsCore
import SwiftUI

/// Text Assistant's page in Mac Tools Settings. Returns form sections only.
struct TextAssistantSettingsView: View {
    @ObservedObject var settings: TextAssistantSettings
    @ObservedObject var permission: AccessibilityPermission
    @ObservedObject var openCode: OpenCodeServer
    @ObservedObject var openRouterCatalog: OpenRouterCatalog
    var keychain = KeychainStore.openRouterKey

    @State private var hasKey = false
    @State private var keyDraft = ""
    @State private var keyError: String?

    var body: some View {
        Section {
            LabeledContent("Improve selected text") {
                KeyboardShortcuts.Recorder(for: .textAssistantImprove)
            }
        } header: {
            Text("Shortcut")
        } footer: {
            Text("No shortcut is set until you record one. Improve Selected Text is also in the Mac Tools menu.")
                .settingsFootnote()
        }

        Section {
            Picker("Use models from", selection: $settings.provider) {
                ForEach(TextAssistantProviderKind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            switch settings.provider {
            case .openCode: openCodeRows
            case .openRouter: openRouterRows
            }
        } header: {
            Text("Model")
        } footer: {
            switch settings.provider {
            case .openCode:
                Text("Text Assistant uses the providers you signed in to with OpenCode, so there is no separate key to add. It runs its own private OpenCode server in the background while you use it and stops it after 10 idle minutes. Runs don’t appear in your OpenCode history.")
                    .settingsFootnote()
            case .openRouter:
                Text("Create a key at openrouter.ai/keys. It is stored only in your Keychain.")
                    .settingsFootnote()
            }
        }
        .task(id: settings.provider) {
            switch settings.provider {
            case .openCode:
                if openCode.executable == nil { await openCode.locate() }
                if openCode.isInstalled, openCode.modelGroups.isEmpty { await openCode.refreshModels() }
            case .openRouter:
                await openRouterCatalog.loadIfNeeded()
            }
        }

        Section {
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
        } header: {
            Text("Permission")
        } footer: {
            Text("Accessibility access lets Text Assistant read your selection and paste the result. Allow Mac Tools in System Settings → Privacy & Security → Accessibility.")
                .settingsFootnote()
        }

        Section {
            Picker("Longest selection", selection: $settings.maxLength) {
                ForEach(TextAssistantSettings.maxLengthChoices, id: \.self) { length in
                    Text("\(length.formatted()) characters").tag(length)
                }
            }
            Picker("Give up after", selection: $settings.timeoutSeconds) {
                ForEach(TextAssistantSettings.timeoutChoices, id: \.self) { seconds in
                    Text("\(seconds) seconds").tag(seconds)
                }
            }
        } header: {
            Text("Limits")
        } footer: {
            Text("Your clipboard is always put back after a run. If a result can’t be pasted, it is left on the clipboard instead, and Copy Last Result in the Mac Tools menu brings it back.")
                .settingsFootnote()
        }
        .onAppear {
            hasKey = keychain.hasValue
            permission.refresh()
        }
    }

    // MARK: OpenCode

    @ViewBuilder private var openCodeRows: some View {
        LabeledContent("OpenCode") {
            HStack(spacing: 8) {
                openCodeStatus
                if openCode.isInstalled {
                    Button("Sign In…") { openCode.openSignIn() }
                        .help("Opens Terminal with “opencode auth login” to add a provider")
                    Button {
                        Task { await openCode.refreshModels(restart: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Reload sign-ins and models")
                    .disabled(openCode.isLoadingModels)
                } else if openCode.executable != nil {
                    Link("Get OpenCode", destination: URL(string: "https://opencode.ai")!)
                    Button("Look Again") { Task { await openCode.locate() } }
                }
            }
        }
        if openCode.isInstalled {
            LabeledContent("Signed in to") {
                Text(signedInProviders)
                    .foregroundStyle(openCode.modelGroups.isEmpty ? .secondary : .primary)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Model") {
                ModelPicker(
                    groups: openCode.modelGroups,
                    selection: $settings.openCodeModel,
                    key: \.id,
                    automaticTitle: automaticOpenCodeTitle,
                    isLoading: openCode.isLoadingModels
                )
            }
            if let error = openCode.modelsError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder private var openCodeStatus: some View {
        if openCode.executable == nil {
            ProgressView().controlSize(.small)
        } else if !openCode.isInstalled {
            Label("Not installed", systemImage: "xmark.circle.fill").foregroundStyle(.secondary)
        } else if case .failed = openCode.state {
            Label("Couldn’t start", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        } else {
            Label(openCode.version.map { "v\($0)" } ?? "Installed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .fixedSize()
        }
    }

    private var signedInProviders: String {
        if openCode.isLoadingModels, openCode.modelGroups.isEmpty { return "Checking…" }
        if openCode.modelGroups.isEmpty { return "No providers yet. Use Sign In…" }
        return openCode.modelGroups.map(\.name).formatted(.list(type: .and))
    }

    private var automaticOpenCodeTitle: String {
        guard let model = openCode.modelGroups.preferredDefault(OpenCodeAPI.preferredModels) else { return "Automatic" }
        return "Automatic · \(model.name)"
    }

    // MARK: OpenRouter

    @ViewBuilder private var openRouterRows: some View {
        if hasKey {
            LabeledContent("API key") {
                HStack {
                    Label("Saved in Keychain", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Button("Remove") { removeKey() }
                }
            }
        }
        LabeledContent(hasKey ? "Replace key" : "API key") {
            HStack {
                SecureField("sk-or-…", text: $keyDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                    .onSubmit(saveKey)
                Button("Save", action: saveKey)
                    .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        if let keyError {
            Label(keyError, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
        LabeledContent("Model") {
            ModelPicker(
                groups: openRouterCatalog.groups,
                selection: $settings.openRouterModel,
                key: \.modelID,
                automaticTitle: OpenRouterAPI.defaultModel,
                isLoading: openRouterCatalog.isLoading
            )
        }
        if let error = openRouterCatalog.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private func saveKey() {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try keychain.save(key)
            keyDraft = ""
            keyError = nil
            hasKey = true
        } catch {
            keyError = error.localizedDescription
        }
    }

    private func removeKey() {
        do {
            try keychain.delete()
            keyError = nil
            hasKey = false
        } catch {
            keyError = error.localizedDescription
        }
    }
}
