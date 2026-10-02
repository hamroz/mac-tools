import AppKit
import KeyboardShortcuts
import MacToolsCore
import SwiftUI

/// Text Assistant's page in Mac Tools Settings. Returns form sections only.
struct TextAssistantSettingsView: View {
    @ObservedObject var settings: TextAssistantSettings
    @ObservedObject var permission: AccessibilityPermission
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
                        .frame(maxWidth: 260)
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
                TextField(OpenRouterAPI.defaultModel, text: $settings.model)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
            }
        } header: {
            Text("OpenRouter")
        } footer: {
            Text("Create a key at openrouter.ai/keys. It is stored only in your Keychain. Any OpenRouter model ID works; leave it empty for \(OpenRouterAPI.defaultModel).")
                .settingsFootnote()
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
