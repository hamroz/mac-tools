import AppKit
import Combine
import MacToolsCore

@MainActor
final class DesktopStickiesModule: NSObject, ToolModule {
    let descriptor = ToolDescriptor(
        id: "desktop-stickies",
        name: "Desktop Stickies",
        symbolName: "note.text"
    )

    private let repository: StickyNoteRepository
    private let windowCoordinator: StickyWindowCoordinator
    private let hotKeyManager: HotKeyManager
    private let workspaceSettings: WorkspaceSettings
    private let launchAtLoginManager = LaunchAtLoginManager()
    private var managerWindow: ManagerWindowController?
    private var settingsWindow: SettingsWindowController?
    private var shortcutObservation: AnyCancellable?
    private var maintenanceTask: Task<Void, Never>?

    init(repository: StickyNoteRepository, hotKeyManager: HotKeyManager = HotKeyManager()) {
        let workspaceSettings = WorkspaceSettings()
        self.workspaceSettings = workspaceSettings
        self.repository = repository
        self.windowCoordinator = StickyWindowCoordinator(repository: repository, workspaceSettings: workspaceSettings)
        self.hotKeyManager = hotKeyManager
        super.init()
        hotKeyManager.onPressed = { [weak self] in
            self?.createNote()
        }
    }

    func start() {
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
    }

    func stop() {
        maintenanceTask?.cancel()
        maintenanceTask = nil
        hotKeyManager.stop()
        windowCoordinator.flushPendingChanges()
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

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettingsFromMenu), keyEquivalent: ",")
        settingsItem.keyEquivalentModifierMask = [.command]
        settingsItem.target = self

        return [newItem, manageItem, .separator(), settingsItem]
    }

    func showManager() {
        repository.purgeDeleted(olderThan: 30)
        if managerWindow == nil {
            managerWindow = ManagerWindowController(
                repository: repository,
                hotKeyManager: hotKeyManager,
                showSettings: { [weak self] in self?.showSettings() },
                openNote: { [weak self] id in self?.windowCoordinator.focus(noteID: id) },
                createNote: { [weak self] in self?.createNote() },
                deleteNote: { [weak self] id in self?.windowCoordinator.moveToRecentlyDeleted(noteID: id) },
                restoreNote: { [weak self] id in self?.windowCoordinator.restore(noteID: id) },
                permanentlyDelete: { [weak self] id in self?.windowCoordinator.permanentlyDelete(noteID: id) }
            )
        }
        managerWindow?.show()
    }

    func showSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(
                hotKeyManager: hotKeyManager,
                launchAtLoginManager: launchAtLoginManager,
                workspaceSettings: workspaceSettings
            )
        }
        settingsWindow?.show()
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

    @objc private func showSettingsFromMenu() {
        showSettings()
    }
}
