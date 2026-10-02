import AppKit
import KeyboardShortcuts
import MacToolsCore
import SwiftUI

/// Text Assistant's page in Mac Tools Settings. Returns form sections only.
struct TextAssistantSettingsView: View {
    @ObservedObject var settings: TextAssistantSettings
    @ObservedObject var configStore: TextAssistantConfigStore
    @ObservedObject var permission: AccessibilityPermission
    @ObservedObject var openCode: OpenCodeServer
    @ObservedObject var openRouterCatalog: OpenRouterCatalog
    var keychain = KeychainStore.openRouterKey

    @State private var hasKey = false
    @State private var keyDraft = ""
    @State private var keyError: String?

    var body: some View {
        Section {
            ForEach($settings.actions) { $action in
                QuickActionRow(action: $action, config: configStore.config) {
                    settings.actions.removeAll { $0.id == action.id }
                }
            }
            HStack {
                Button {
                    let config = configStore.config
                    settings.actions.append(TextAction(
                        modeID: config.modes.first?.id ?? "improve",
                        toneID: config.tone(id: "my-style")?.id ?? config.tones.first?.id ?? "my-style"
                    ))
                } label: {
                    Label("Add Action", systemImage: "plus")
                }
                Spacer()
                if settings.actions != TextAction.defaults {
                    Button("Restore Defaults") { settings.actions = TextAction.defaults }
                }
            }
        } header: {
            Text("Quick Actions")
        } footer: {
            Text("Each action runs on the selected text from the Mac Tools menu. Shortcuts are optional; none is set until you record one.")
                .settingsFootnote()
        }

        Section {
            LabeledContent("Modes and tones") {
                HStack {
                    Text("\(configStore.config.modes.count) modes · \(configStore.config.tones.count) tones")
                        .foregroundStyle(.secondary)
                    Button("Edit…") { configStore.open(configStore.configURL) }
                }
            }
            if let problem = configStore.problem {
                VStack(alignment: .leading, spacing: 6) {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("The last working version stays in use until the file is fixed.")
                        .settingsFootnote()
                    Button("Restore Default Modes and Tones…") { configStore.restoreDefaultConfig() }
                }
                .font(.callout)
            }
            LabeledContent("My style samples") {
                HStack {
                    Text(styleSummary)
                        .foregroundStyle(.secondary)
                    Button("Edit…") { configStore.open(configStore.styleURL) }
                }
            }
            HStack {
                Spacer()
                Button("Show in Finder") { configStore.showInFinder() }
            }
        } header: {
            Text("Modes, Tones and My Style")
        } footer: {
            Text("config.json holds the modes (what to do), the tones (how it should sound) and the prompts; add your own, like “Reply” or “Explain simply”. my-style.md holds samples of your own writing for the My style tone. Changes apply as soon as you save. Restoring the defaults keeps your old file as a backup.")
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

    private var styleSummary: String {
        guard let samples = configStore.styleSamples else { return "None yet" }
        return "\(samples.count.formatted()) characters"
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

/// One quick action: its mode, its tone, an optional shortcut, and a remove button.
private struct QuickActionRow: View {
    @Binding var action: TextAction
    let config: TextAssistantConfig
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Picker("Mode", selection: $action.modeID) {
                ForEach(config.modes) { Text($0.name).tag($0.id) }
                if config.mode(id: action.modeID) == nil { Text("“\(action.modeID)” (missing)").tag(action.modeID) }
            }
            .labelsHidden()
            .fixedSize()
            Picker("Tone", selection: $action.toneID) {
                ForEach(config.tones) { Text($0.name).tag($0.id) }
                if config.tone(id: action.toneID) == nil { Text("“\(action.toneID)” (missing)").tag(action.toneID) }
            }
            .labelsHidden()
            .fixedSize()
            Spacer(minLength: 8)
            KeyboardShortcuts.Recorder(for: action.shortcutName)
            Button(action: remove) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove this action")
            .accessibilityLabel("Remove \(action.title(in: config))")
        }
    }
}
