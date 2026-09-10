import AppKit
import MacToolsCore
import SwiftUI

@MainActor
final class ManagerWindowController: NSWindowController {
    init(
        repository: StickyNoteRepository,
        hotKeyManager: HotKeyManager,
        showSettings: @escaping () -> Void,
        openNote: @escaping (UUID) -> Void,
        createNote: @escaping () -> Void,
        deleteNote: @escaping (UUID) -> Void,
        restoreNote: @escaping (UUID) -> Void,
        permanentlyDelete: @escaping (UUID) -> Void
    ) {
        let rootView = NotesManagerView(
            repository: repository,
            hotKeyManager: hotKeyManager,
            showSettings: showSettings,
            openNote: openNote,
            createNote: createNote,
            deleteNote: deleteNote,
            restoreNote: restoreNote,
            permanentlyDelete: permanentlyDelete
        )
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 660, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Desktop Stickies"
        window.minSize = CGSize(width: 520, height: 380)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: rootView)
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private enum ManagerSection: String, CaseIterable, Identifiable {
    case active = "Active"
    case deleted = "Recently Deleted"

    var id: String { rawValue }
}

private struct NotesManagerView: View {
    @ObservedObject var repository: StickyNoteRepository
    @ObservedObject var hotKeyManager: HotKeyManager
    let showSettings: () -> Void
    let openNote: (UUID) -> Void
    let createNote: () -> Void
    let deleteNote: (UUID) -> Void
    let restoreNote: (UUID) -> Void
    let permanentlyDelete: (UUID) -> Void

    @State private var section: ManagerSection = .active
    @State private var pendingPermanentDelete: StickyNoteRecord?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let warning = repository.warningMessage {
                warningBanner(warning, symbol: "exclamationmark.triangle.fill", color: .orange)
            }
            if let saveError = repository.lastSaveError {
                warningBanner(saveError, symbol: "externaldrive.badge.exclamationmark", color: .red)
                Button("Try Saving Again") { repository.retrySave() }
                    .padding(.bottom, 8)
            }

            if displayedNotes.isEmpty {
                emptyState
            } else {
                List(displayedNotes) { note in
                    NoteManagerRow(
                        note: note,
                        section: section,
                        openNote: openNote,
                        deleteNote: deleteNote,
                        restoreNote: restoreNote,
                        requestPermanentDelete: { pendingPermanentDelete = note }
                    )
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 520, minHeight: 380)
        .alert(
            "Delete this note permanently?",
            isPresented: Binding(
                get: { pendingPermanentDelete != nil },
                set: { if !$0 { pendingPermanentDelete = nil } }
            ),
            presenting: pendingPermanentDelete
        ) { note in
            Button("Delete Permanently", role: .destructive) {
                permanentlyDelete(note.id)
                pendingPermanentDelete = nil
            }
            Button("Cancel", role: .cancel) {
                pendingPermanentDelete = nil
            }
        } message: { _ in
            Text("This action cannot be undone.")
        }
    }

    private var displayedNotes: [StickyNoteRecord] {
        section == .active ? repository.activeNotes : repository.deletedNotes
    }

    private var header: some View {
        HStack(spacing: 16) {
            Picker("Section", selection: $section) {
                ForEach(ManagerSection.allCases) { section in
                    Text(section.rawValue).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 330)

            Spacer()

            Button(action: showSettings) {
                Image(systemName: "gearshape")
            }
            .help("Settings")
            .accessibilityLabel("Settings")
            .keyboardShortcut(",", modifiers: .command)

            Button(action: createNote) {
                Label("New Note", systemImage: "plus")
            }
            .keyboardShortcut(KeyEquivalent(Character(hotKeyManager.preset.keyEquivalent)), modifiers: hotKeyManager.preset.swiftUIModifiers)
        }
        .padding(16)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(
                section == .active ? "No Notes" : "Recently Deleted Is Empty",
                systemImage: section == .active ? "note.text" : "trash"
            )
        } description: {
            Text(section == .active ? "Create a note and place it on your desktop." : "Deleted notes remain here for 30 days.")
        } actions: {
            if section == .active {
                Button("New Note", action: createNote)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func warningBanner(_ text: String, symbol: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).font(.callout)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(color.opacity(0.08))
    }
}

private struct NoteManagerRow: View {
    let note: StickyNoteRecord
    let section: ManagerSection
    let openNote: (UUID) -> Void
    let deleteNote: (UUID) -> Void
    let restoreNote: (UUID) -> Void
    let requestPermanentDelete: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(note.palette.backgroundColor(for: colorScheme))
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(.primary.opacity(0.1), lineWidth: 1)
                }
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text(preview)
                    .font(.body)
                    .lineLimit(1)
                Text(timestampLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 16)

            if section == .active {
                Button("Open") { openNote(note.id) }
                Button {
                    deleteNote(note.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Move to Recently Deleted")
            } else {
                Button("Restore") { restoreNote(note.id) }
                Button {
                    requestPermanentDelete()
                } label: {
                    Image(systemName: "trash.fill")
                }
                .buttonStyle(.borderless)
                .help("Delete permanently")
            }
        }
        .padding(.vertical, 5)
    }

    private var preview: String {
        let trimmed = note.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Empty note" : trimmed.replacingOccurrences(of: "\n", with: " ")
    }

    private var timestampLabel: String {
        let date = section == .active ? note.updatedAt : (note.deletedAt ?? note.updatedAt)
        let prefix = section == .active ? "Updated" : "Deleted"
        return "\(prefix) \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}
