import AppKit
import Combine
import KeyboardShortcuts
import MacToolsCore
import SwiftUI

@MainActor
final class TextAssistantModule: NSObject, ToolModule {
    let descriptor = ToolDescriptor(
        id: "text-assistant",
        name: "Text Assistant",
        summary: "Improves or translates the text you’ve selected in any app and puts the result right back in place.",
        symbolName: "wand.and.stars",
        tint: .teal
    )

    var openSettings: (() -> Void)?

    let settings: TextAssistantSettings
    let configStore: TextAssistantConfigStore
    let runner: TextAssistantRunner
    let openCode: OpenCodeServer
    private let openRouterCatalog = OpenRouterCatalog()
    private let hud: TextAssistantHUD
    private let popup = TextAssistantPopup()
    private var popupTask: Task<Void, Never>?
    private var refreshMenu: (() -> Void)?
    private var registeredShortcuts: [KeyboardShortcuts.Name] = []
    private var observers: [AnyCancellable] = []
    private var menuObservers: [AnyCancellable] = []

    init(
        settings: TextAssistantSettings = TextAssistantSettings(),
        configStore: TextAssistantConfigStore = TextAssistantConfigStore(),
        openCode: OpenCodeServer = OpenCodeServer()
    ) {
        self.settings = settings
        self.configStore = configStore
        self.openCode = openCode
        let hud = TextAssistantHUD()
        self.hud = hud
        runner = TextAssistantRunner(
            settings: settings,
            configStore: configStore,
            bridge: TextSelectionBridge(pasteboard: SystemPasteboard(), environment: SystemSelectionEnvironment()),
            feedback: hud,
            makeProvider: { settings in
                let timeout = TimeInterval(settings.timeoutSeconds)
                switch settings.provider {
                case .openCode: return OpenCodeProvider(server: openCode, timeout: timeout)
                case .openRouter: return OpenRouterProvider(timeout: timeout)
                }
            }
        )
        super.init()
        hud.onOpenSettings = { [weak self] in self?.openSettings?() }
        runner.onAccessibilityMissing = { [weak self] in
            AccessibilityPermission.shared.request()
            self?.openSettings?()
        }
        popup.onCancel = { [weak self] in self?.popupTask?.cancel() }
    }

    func start() {
        configStore.start()
        registerShortcuts(for: settings.actions)
        KeyboardShortcuts.onKeyDown(for: .textAssistantPopup) { [weak self] in self?.openPopup() }
        applyTriggerSwitches()
        observers = [
            settings.$actions.dropFirst().sink { [weak self] actions in
                self?.registerShortcuts(for: actions)
                self?.applyTriggerSwitches()
                self?.refreshMenu?()
            },
            Publishers.Merge(settings.$quickActionsEnabled.dropFirst(), settings.$popupEnabled.dropFirst())
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    self?.applyTriggerSwitches()
                    self?.refreshMenu?()
                },
            // Mode and tone names appear in the menu.
            configStore.$config.dropFirst().removeDuplicates().sink { [weak self] _ in self?.refreshMenu?() },
        ]
    }

    func stop() {
        observers.removeAll()
        registeredShortcuts.forEach(KeyboardShortcuts.removeHandler(for:))
        registeredShortcuts = []
        KeyboardShortcuts.removeHandler(for: .textAssistantPopup)
        popupTask?.cancel()
        popup.close()
        configStore.stop()
        runner.cancel()
        hud.hide()
        openCode.stop()
    }

    func setMenuRefresh(_ refresh: @escaping () -> Void) {
        refreshMenu = refresh
    }

    func makeMenuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if settings.popupEnabled {
            let open = NSMenuItem(title: "Open Text Assistant…", action: #selector(openPopupFromMenu), keyEquivalent: "")
            open.target = self
            open.setShortcut(for: .textAssistantPopup)
            items.append(open)
        }
        items += (settings.quickActionsEnabled ? settings.actions : []).map { action in
            let item = NSMenuItem(title: title(for: action), action: #selector(runFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action.id
            item.setShortcut(for: action.shortcutName)
            return item
        }
        let copyLast = NSMenuItem(title: "Copy Last Result", action: #selector(copyLastResult), keyEquivalent: "")
        copyLast.target = self
        menuObservers = [runner.$lastResult.sink { [weak copyLast] result in copyLast?.isHidden = result == nil }]
        items.append(copyLast)
        return items
    }

    func makeSettingsView() -> AnyView {
        AnyView(TextAssistantSettingsView(
            settings: settings, configStore: configStore, permission: .shared,
            openCode: openCode, openRouterCatalog: openRouterCatalog
        ))
    }

    /// "Improve · My style", or the IDs when config.json no longer has them.
    func title(for action: TextAction) -> String {
        action.title(in: configStore.config)
    }

    /// Recorded shortcuts that are switched on, for the Shortcuts tool.
    var shortcutEntries: [(shortcut: KeyboardShortcuts.Shortcut, action: String)] {
        var entries: [(shortcut: KeyboardShortcuts.Shortcut, action: String)] = []
        if settings.popupEnabled, let popup = KeyboardShortcuts.getShortcut(for: .textAssistantPopup) {
            entries.append((popup, "Open Text Assistant"))
        }
        guard settings.quickActionsEnabled else { return entries }
        return entries + settings.actions.compactMap { action in
            KeyboardShortcuts.getShortcut(for: action.shortcutName).map { ($0, title(for: action)) }
        }
    }

    /// The shortcuts that are switched on, so pausing and resuming leaves the others off.
    var shortcutNames: [KeyboardShortcuts.Name] {
        (settings.popupEnabled ? [.textAssistantPopup] : []) + (settings.quickActionsEnabled ? settings.actions.map(\.shortcutName) : [])
    }

    /// The popup and the quick actions can each be switched off; their shortcuts then do nothing.
    private func applyTriggerSwitches() {
        if settings.popupEnabled { KeyboardShortcuts.enable(.textAssistantPopup) } else { KeyboardShortcuts.disable(.textAssistantPopup) }
        let names = settings.actions.map(\.shortcutName)
        if settings.quickActionsEnabled { KeyboardShortcuts.enable(names) } else { KeyboardShortcuts.disable(names) }
    }

    // MARK: Popup

    func openPopup() {
        guard settings.popupEnabled else { return }
        popupTask?.cancel()
        hud.hide()
        configStore.reloadIfChanged()
        let start = settings.popupStart(in: configStore.config)
        popup.show(config: configStore.config, modeID: start.modeID, toneID: start.toneID)
        if settings.provider == .openCode {
            // Start OpenCode while the user picks, so the run doesn't wait for it.
            Task { [openCode] in _ = try? await openCode.connect() }
        }
        popupTask = Task { [weak self] in
            guard let self else { return }
            do {
                let selection = try await self.runner.captureSelection()
                guard !Task.isCancelled else { return }
                self.popup.onRun = { [weak self] modeID, toneID in
                    self?.settings.rememberPopupChoice(modeID: modeID, toneID: toneID)
                    self?.runner.run(modeID: modeID, toneID: toneID, selection: selection)
                }
                self.popup.present(selection: selection.text)
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                self.popup.close()
                self.hud.show(.failure((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
            }
        }
    }

    @objc private func openPopupFromMenu() {
        // Let the menu finish closing so the selection is read from the app, not the menu.
        DispatchQueue.main.async { [weak self] in self?.openPopup() }
    }

    private func registerShortcuts(for actions: [TextAction]) {
        let names = actions.map(\.shortcutName)
        for name in registeredShortcuts where !names.contains(name) {
            KeyboardShortcuts.removeHandler(for: name)
            // A removed action must not leave its shortcut stored or registered.
            KeyboardShortcuts.reset(name)
        }
        for name in names where !registeredShortcuts.contains(name) {
            KeyboardShortcuts.onKeyDown(for: name) { [weak self] in
                guard let self, let action = self.settings.actions.first(where: { $0.shortcutName == name }) else { return }
                self.runner.run(action)
            }
        }
        registeredShortcuts = names
    }

    /// The status menu never activates Mac Tools, so the selection stays in the frontmost app.
    @objc private func runFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let action = settings.actions.first(where: { $0.id == id }) else { return }
        // Let the menu finish closing before keystrokes go to the app.
        DispatchQueue.main.async { [weak self] in self?.runner.run(action) }
    }

    @objc private func copyLastResult() {
        guard let result = runner.lastResult else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result, forType: .string)
    }
}
