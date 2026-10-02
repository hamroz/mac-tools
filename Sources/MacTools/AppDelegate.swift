import AppKit
import MacToolsCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var registry: ToolRegistry?
    private var desktopProbe: DesktopProbe?
    private let launchAtLoginManager = LaunchAtLoginManager()
    private var settingsWindow: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        if Bundle.main.bundleIdentifier == "com.local.MacTools.DesktopProbe" {
            configureMainMenu()
            let probe = DesktopProbe()
            desktopProbe = probe
            probe.start()
            return
        }

        Self.removeRetiredPreferences()

        let repository = StickyNoteRepository()
        let stickies = DesktopStickiesModule(repository: repository)
        let registry = ToolRegistry(modules: [stickies, AIUsageModule()])
        registry.onChange = { [weak self] in self?.rebuildStatusMenu() }
        registry.onOpenSettings = { [weak self] id in self?.showSettings(.tool(id)) }
        self.registry = registry

        configureStatusItem()
        configureMainMenu()
        registry.startAll()
    }

    func applicationWillTerminate(_ notification: Notification) {
        desktopProbe?.stop()
        registry?.stopAll()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let desktopProbe { desktopProbe.showControls(); return true }
        showSettings()
        return true
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "square.stack.3d.up.fill", accessibilityDescription: "Mac Tools")
            button.toolTip = "Mac Tools"
        }
        statusItem = item
        rebuildStatusMenu()
    }

    private func rebuildStatusMenu() {
        guard let statusItem, let registry else { return }
        let menu = registry.makeMenu()
        if registry.enabledModules.isEmpty {
            let empty = NSMenuItem(title: "No Tools Turned On", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            menu.addItem(.separator())
        }

        let settingsItem = NSMenuItem(title: "Mac Tools Settings…", action: #selector(showSettingsFromMenu), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Mac Tools", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    /// Mac Tools has no Dock icon; this menu only supplies key equivalents while one of its windows is active.
    private func configureMainMenu() {
        let mainMenu = NSMenu()
        let appMenu = NSMenu()
        if registry != nil {
            let settings = NSMenuItem(title: "Settings…", action: #selector(showSettingsFromMenu), keyEquivalent: ",")
            settings.target = self
            appMenu.addItem(settings)
            appMenu.addItem(.separator())
        }
        appMenu.addItem(withTitle: "Quit Mac Tools", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        let edit = NSMenu(title: "Edit")
        for (title, action, key) in [
            ("Undo", "undo:", "z"), ("Redo", "redo:", "Z"),
            ("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
            ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")
        ] {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    private func showSettings(_ pane: SettingsPane? = nil) {
        guard let registry else { return }
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(registry: registry, launchAtLoginManager: launchAtLoginManager)
        }
        settingsWindow?.show(pane)
    }

    /// Clears preferences left behind by the removed Menu Bar Organizer.
    private static func removeRetiredPreferences(defaults: UserDefaults = .standard) {
        let retired = defaults.dictionaryRepresentation().keys.filter {
            $0.hasPrefix("menuBarOrganizer.") || $0.hasSuffix(" MacTools.Organizer.Menu") || $0.hasSuffix(" MacTools.Organizer.Divider")
        }
        retired.forEach(defaults.removeObject(forKey:))
    }

    @objc private func showSettingsFromMenu() { showSettings() }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
