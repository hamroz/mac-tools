import AppKit
import Combine
import MacToolsCore
import SwiftUI

@MainActor
final class DesktopStickiesModule: NSObject, ToolModule {
    let descriptor = ToolDescriptor(
        id: "desktop-stickies",
        name: "Desktop Stickies",
        summary: "Notes that live on your desktop, behind your app windows.",
        symbolName: "note.text",
        tint: .yellow
    )

    var openSettings: (() -> Void)?

    private let repository: StickyNoteRepository
    private let windowCoordinator: StickyWindowCoordinator
    private let hotKeyManager: HotKeyManager
    private let workspaceSettings: WorkspaceSettings
    private let overviewMonitor: DockOverviewMonitor
    private let overviewProbe: DockOverviewOverlayProbe
    private var managerWindow: ManagerWindowController?
    private var shortcutObservation: AnyCancellable?
    private var maintenanceTask: Task<Void, Never>?
    private var isRunning = false

    init(repository: StickyNoteRepository, hotKeyManager: HotKeyManager = HotKeyManager()) {
        let workspaceSettings = WorkspaceSettings()
        self.workspaceSettings = workspaceSettings
        self.repository = repository
        let presentation = DesktopPresentation()
        self.overviewMonitor = DockOverviewMonitor(presentation: presentation)
        self.overviewProbe = DockOverviewOverlayProbe(presentation: presentation)
        self.windowCoordinator = StickyWindowCoordinator(repository: repository, workspaceSettings: workspaceSettings,
                                                        desktopPresentation: presentation)
        self.hotKeyManager = hotKeyManager
        super.init()
        hotKeyManager.onPressed = { [weak self] in
            self?.createNote()
        }
    }

    func start() {
        isRunning = true
        overviewMonitor.start()
        overviewProbe.start()
        windowCoordinator.restoreActiveNotes()
        hotKeyManager.start()
        maintenanceTask?.cancel()
        maintenanceTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3600)) }
                catch { break }
                self?.repository.purgeDeleted(olderThan: 30)
            }
        }
        // Explain permission/synchronization without silently requesting access.
        if !UserDefaults.standard.bool(forKey: "desktopPinningSetupShown") {
            UserDefaults.standard.set(true, forKey: "desktopPinningSetupShown")
            openSettings?()
        }
    }

    func stop() {
        isRunning = false
        maintenanceTask?.cancel()
        maintenanceTask = nil
        hotKeyManager.stop()
        windowCoordinator.closeAll()
        managerWindow?.close()
        overviewProbe.stop()
        overviewMonitor.stop()
    }

    /// The New Note shortcut, read by the Shortcuts tool.
    var hotKeyPreset: HotKeyPreset { hotKeyManager.preset }

    /// Lets the Shortcuts checker record New Note's combination without creating a note.
    func setHotKeyPaused(_ paused: Bool) {
        guard isRunning else { return }
        if paused { hotKeyManager.stop() } else { hotKeyManager.start() }
    }

    func makeMenuItems() -> [NSMenuItem] {
        let newItem = NSMenuItem(title: "New Note", action: #selector(createNoteFromMenu), keyEquivalent: "n")
        newItem.target = self
        shortcutObservation = hotKeyManager.$preset.sink { [weak newItem] preset in
            newItem?.keyEquivalent = preset.keyEquivalent
            newItem?.keyEquivalentModifierMask = preset.appKitModifiers
        }

        let manageItem = NSMenuItem(title: "Manage Notes…", action: #selector(showManagerFromMenu), keyEquivalent: "m")
        manageItem.keyEquivalentModifierMask = [.command]
        manageItem.target = self

        return [newItem, manageItem]
    }

    func makeSettingsView() -> AnyView {
        AnyView(DesktopStickiesSettingsView(
            repository: repository,
            hotKeyManager: hotKeyManager,
            workspaceSettings: workspaceSettings,
            overviewMonitor: overviewMonitor,
            showManager: { [weak self] in self?.showManager() }
        ))
    }

    func showManager() {
        repository.purgeDeleted(olderThan: 30)
        if managerWindow == nil {
            managerWindow = ManagerWindowController(
                repository: repository,
                hotKeyManager: hotKeyManager,
                showSettings: { [weak self] in self?.openSettings?() },
                openNote: { [weak self] id in self?.windowCoordinator.focus(noteID: id) },
                createNote: { [weak self] in self?.createNote() },
                deleteNote: { [weak self] id in self?.windowCoordinator.moveToRecentlyDeleted(noteID: id) },
                restoreNote: { [weak self] id in self?.windowCoordinator.restore(noteID: id) },
                permanentlyDelete: { [weak self] id in self?.windowCoordinator.permanentlyDelete(noteID: id) }
            )
        }
        managerWindow?.show()
    }

    private func createNote() {
        windowCoordinator.createNoteNearPointer()
    }

    @objc private func createNoteFromMenu() {
        createNote()
    }

    @objc private func showManagerFromMenu() {
        showManager()
    }
}
