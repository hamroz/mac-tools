import AppKit
import MacToolsCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var registry: ToolRegistry?
    private var desktopProbe: DesktopProbe?
    private var organizerModule: MenuBarOrganizerModule?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        if Bundle.main.bundleIdentifier == "com.local.MacTools.DesktopProbe" {
            configureEditingMenu()
            let probe = DesktopProbe()
            desktopProbe = probe
            probe.start()
            return
        }

        let repository = StickyNoteRepository()
        let stickies = DesktopStickiesModule(repository: repository)
        let organizer = MenuBarOrganizerModule()
        organizerModule = organizer
        let registry = ToolRegistry(modules: [stickies, organizer])
        self.registry = registry

        configureStatusItem(for: registry)
        configureEditingMenu()
        registry.startAll()
    }

    func applicationWillTerminate(_ notification: Notification) {
        desktopProbe?.stop()
        registry?.stopAll()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let desktopProbe { desktopProbe.showControls(); return true }
        registry?.modules.first?.showManager()
        return true
    }

    private func configureStatusItem(for registry: ToolRegistry) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "square.stack.3d.up.fill", accessibilityDescription: "Mac Tools")
            button.toolTip = "Mac Tools"
        }

        let menu = registry.makeMenu()

        let quitItem = NSMenuItem(title: "Quit Mac Tools", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        item.menu = menu
        statusItem = item
    }

    private func configureEditingMenu() {
        let mainMenu = NSMenu()
        let appMenu = NSMenu()
        if organizerModule != nil {
            let organizer = NSMenuItem(title: "Menu Bar Organizer…", action: #selector(showOrganizer), keyEquivalent: ",")
            organizer.target = self
            appMenu.addItem(organizer)
            let tray = NSMenuItem(title: "Hidden Menu Bar Items", action: #selector(showHiddenMenuItems), keyEquivalent: "m")
            tray.keyEquivalentModifierMask = [.command, .option]
            tray.target = self
            appMenu.addItem(tray)
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

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func showOrganizer() { organizerModule?.showSettings() }
    @objc private func showHiddenMenuItems() { organizerModule?.showHiddenItems() }
}
