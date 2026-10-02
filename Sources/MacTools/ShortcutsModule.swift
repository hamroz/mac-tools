import AppKit
import Combine
import KeyboardShortcuts
import MacToolsCore
import SwiftUI

extension KeyboardShortcuts.Name {
    /// No default: global shortcuts are the user's to choose.
    static let shortcutsShowWindow = Self("shortcuts.showWindow")
}

@MainActor
final class ShortcutsSettings: ObservableObject {
    @Published var captureMenusAutomatically: Bool {
        didSet { defaults.set(captureMenusAutomatically, forKey: Self.captureKey) }
    }

    private let defaults: UserDefaults
    private static let captureKey = "shortcuts.captureMenusAutomatically"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        captureMenusAutomatically = defaults.object(forKey: Self.captureKey) as? Bool ?? true
    }
}

/// Mac Tools' own global shortcuts, read live from each tool.
enum MacToolsShortcutSource {
    static func entries(
        stickiesPreset: HotKeyPreset?,
        textAssistant: KeyboardShortcuts.Shortcut?,
        shortcutsWindow: KeyboardShortcuts.Shortcut?
    ) -> [ShortcutEntry] {
        var entries: [ShortcutEntry] = []
        if let preset = stickiesPreset {
            let modifiers = preset.modifiers.reduce(into: ShortcutModifiers()) { result, modifier in
                switch modifier {
                case .control: result.insert(.control)
                case .option: result.insert(.option)
                case .shift: result.insert(.shift)
                case .command: result.insert(.command)
                }
            }
            entries.append(entry(KeyCombo(keyCode: UInt16(preset.keyCode), modifiers: modifiers), "New Note", "Desktop Stickies"))
        }
        if let shortcut = textAssistant, let combo = combo(shortcut) {
            entries.append(entry(combo, "Improve selected text", "Text Assistant"))
        }
        if let shortcut = shortcutsWindow, let combo = combo(shortcut) {
            entries.append(entry(combo, "Show Shortcuts", "Shortcuts"))
        }
        return entries
    }

    private static func combo(_ shortcut: KeyboardShortcuts.Shortcut) -> KeyCombo? {
        guard (0...0x7F).contains(shortcut.carbonKeyCode) else { return nil }
        return KeyCombo(keyCode: UInt16(shortcut.carbonKeyCode), modifiers: ShortcutModifiers(carbon: shortcut.carbonModifiers))
    }

    private static func entry(_ combo: KeyCombo, _ action: String, _ tool: String) -> ShortcutEntry {
        ShortcutEntry(combo: combo, action: action, detail: tool, source: .macTools, scope: .global)
    }
}

@MainActor
final class ShortcutsModule: NSObject, ToolModule {
    let descriptor = ToolDescriptor(
        id: "shortcuts",
        name: "Shortcuts",
        summary: "Every keyboard shortcut on your Mac in one place, and a checker for whether a new one is free.",
        symbolName: "command.square.fill",
        tint: .indigo
    )

    var openSettings: (() -> Void)?
    /// Set by the app: pauses Mac Tools' own global hotkeys while the checker records a combination.
    var pauseHotKeys: ((Bool) -> Void)?

    let store: ShortcutsStore
    let settings: ShortcutsSettings
    private var windowController: ShortcutsWindowController?
    private var launchObserver: NSObjectProtocol?
    private var captureTasks: [pid_t: Task<Void, Never>] = [:]

    /// How long to wait after an app launches before reading its menus, so they exist.
    private static let launchCaptureDelay: Duration = .seconds(3)

    init(store: ShortcutsStore, settings: ShortcutsSettings = ShortcutsSettings()) {
        self.store = store
        self.settings = settings
        super.init()
    }

    func start() {
        KeyboardShortcuts.onKeyDown(for: .shortcutsShowWindow) { [weak self] in
            self?.show(.allGlobal)
        }
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.scheduleCapture(of: app) }
        }
    }

    func stop() {
        KeyboardShortcuts.removeHandler(for: .shortcutsShowWindow)
        if let launchObserver { NSWorkspace.shared.notificationCenter.removeObserver(launchObserver) }
        launchObserver = nil
        captureTasks.values.forEach { $0.cancel() }
        captureTasks.removeAll()
        windowController?.close()
    }

    func makeMenuItems() -> [NSMenuItem] {
        let show = NSMenuItem(title: "Show Shortcuts…", action: #selector(showFromMenu), keyEquivalent: "")
        show.target = self
        show.setShortcut(for: .shortcutsShowWindow)
        let check = NSMenuItem(title: "Check a Shortcut…", action: #selector(checkFromMenu), keyEquivalent: "")
        check.target = self
        return [show, check]
    }

    func makeSettingsView() -> AnyView {
        AnyView(ShortcutsSettingsView(
            settings: settings, store: store, permission: .shared,
            openWindow: { [weak self] in self?.show(.allGlobal) }
        ))
    }

    func show(_ page: ShortcutsPage) {
        if windowController == nil {
            windowController = ShortcutsWindowController(
                store: store,
                pauseHotKeys: { [weak self] paused in self?.pauseHotKeys?(paused) }
            )
        }
        windowController?.show(page)
    }

    private func scheduleCapture(of app: NSRunningApplication) {
        guard settings.captureMenusAutomatically, app.activationPolicy == .regular else { return }
        let pid = app.processIdentifier
        captureTasks[pid]?.cancel()
        captureTasks[pid] = Task { [weak self] in
            try? await Task.sleep(for: Self.launchCaptureDelay)
            guard !Task.isCancelled, let self else { return }
            await self.store.capture(app: app)
            self.captureTasks[pid] = nil
        }
    }

    @objc private func showFromMenu() { show(.allGlobal) }
    @objc private func checkFromMenu() { show(.check) }
}
