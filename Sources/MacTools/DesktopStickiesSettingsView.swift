import AppKit
import MacToolsCore
import SwiftUI

/// Desktop Stickies' page in Mac Tools Settings. Returns form sections only;
/// the settings window supplies the tool header and on/off switch.
struct DesktopStickiesSettingsView: View {
    @ObservedObject var repository: StickyNoteRepository
    @ObservedObject var hotKeyManager: HotKeyManager
    @ObservedObject var workspaceSettings: WorkspaceSettings
    @ObservedObject var overviewMonitor: DockOverviewMonitor
    let showManager: () -> Void

    var body: some View {
        Section("Notes") {
            LabeledContent("On the desktop") {
                Text(repository.activeNotes.count, format: .number)
            }
            LabeledContent("Recently deleted") {
                Text(repository.deletedNotes.count, format: .number)
            }
            LabeledContent("New Note shortcut") {
                Picker("New Note shortcut", selection: hotKeyBinding) {
                    ForEach(HotKeyPreset.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            if let error = hotKeyManager.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Manage Notes…", action: showManager)
            }
        }

        Section {
            Picker("Show notes on", selection: workspaceBinding) {
                ForEach(NoteWorkspaceMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)
        } header: {
            Text("Workspaces")
        } footer: {
            Text("\(workspaceSettings.mode.explanation) Applies to all existing and new notes.")
                .settingsFootnote()
        }

        Section {
            LabeledContent("Mission Control fallback") {
                HStack {
                    Button("Enable Accessibility…") { overviewMonitor.requestPermission() }
                    Button("Recheck") { overviewMonitor.retry() }
                }
            }
            Text(overviewMonitor.status)
                .settingsFootnote()
        } header: {
            Text("Show Desktop")
        } footer: {
            Text("Notes stay pinned and editable during Show Desktop (Command–F3 or a hot corner) and disappear in Mission Control. Accessibility access is optional; it adds a fallback Dock observer that synchronizes after one Show Desktop cycle.")
                .settingsFootnote()
        }

        Section {
            LabeledContent("Notes file") {
                Button("Show in Finder") {
                    let url = repository.storageURL
                    if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } else {
                        NSWorkspace.shared.open(url.deletingLastPathComponent())
                    }
                }
            }
        } header: {
            Text("Storage")
        } footer: {
            Text(repository.storageURL.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .settingsFootnote()
                .textSelection(.enabled)
        }
    }

    private var workspaceBinding: Binding<NoteWorkspaceMode> {
        Binding(get: { workspaceSettings.mode }, set: { workspaceSettings.setMode($0) })
    }

    private var hotKeyBinding: Binding<HotKeyPreset> {
        Binding(get: { hotKeyManager.preset }, set: { hotKeyManager.setPreset($0) })
    }
}
