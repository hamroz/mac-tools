import AppKit
import Combine
import MacToolsCore

@MainActor
final class MenuBarOrganizerModule: NSObject, ToolModule, NSMenuDelegate {
    let descriptor = ToolDescriptor(
        id: "menu-bar-organizer",
        name: "Menu Bar Organizer",
        symbolName: "menubar.arrow.up.rectangle"
    )

    private let settings: MenuBarOrganizerSettings
    private let controller: MenuBarOrganizerController
    private var statusItem: NSStatusItem?
    private var enableMenuItem: NSMenuItem?
    private var enabledObservation: AnyCancellable?
    private var revealObservation: AnyCancellable?
    private var settingsWindow: MenuBarOrganizerSettingsWindowController?
    private let tray = MenuBarTrayController()

    init(settings: MenuBarOrganizerSettings = MenuBarOrganizerSettings(),
         controller: MenuBarOrganizerController? = nil) {
        self.settings = settings
        self.controller = controller ?? MenuBarOrganizerController(scanner: AXMenuBarItemScanner(), settings: settings)
        super.init()
        self.controller.beforeCollapse = { [weak self] items in await self?.tray.icons.refresh(items) }
        if let section = self.controller.section as? MenuBarSection {
            section.accessButtonFrame = { [weak self] in
                guard let frame = self?.statusItem?.button?.window?.frame else { return nil }
                return MenuBarCoordinates.quartzFrame(frame)
            }
        }
        enabledObservation = settings.$isEnabled.dropFirst().sink { [weak self] enabled in
            self?.updateStatusItem(enabled: enabled)
        }
        revealObservation = self.controller.$isRevealed.sink { [weak self] revealed in
            self?.updateStatusItemImage(revealed: revealed)
        }
    }

    func start() {
        MenuBarSection.prepareSavedPositions()
        updateStatusItem(enabled: settings.isEnabled)
        controller.start()
    }

    func stop() {
        tray.close()
        controller.stop()
        removeStatusItem()
    }

    func makeMenuItems() -> [NSMenuItem] {
        let enableItem = NSMenuItem(
            title: "Enable Menu Bar Organizer",
            action: #selector(toggleEnabledFromMenu),
            keyEquivalent: ""
        )
        enableItem.target = self
        enableItem.state = settings.isEnabled ? .on : .off
        enableMenuItem = enableItem

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettingsFromMenu), keyEquivalent: "")
        settingsItem.target = self

        return [enableItem, settingsItem]
    }

    func showManager() {
        showSettings()
    }

    func showHiddenItems() {
        guard let button = statusItem?.button else { showSettings(); return }
        toggleTray(button)
    }

    func showSettings() {
        if settingsWindow == nil {
            settingsWindow = MenuBarOrganizerSettingsWindowController(settings: settings, controller: controller, icons: tray.icons)
        }
        settingsWindow?.show()
    }

    func makeOrganizerMenu() -> NSMenu {
        let menu = NSMenu(title: "Menu Bar Organizer")
        menu.delegate = self
        rebuildOrganizerMenu(menu)
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildOrganizerMenu(menu)
    }

    func menuWillOpen(_ menu: NSMenu) { controller.isMenuOpen = true }
    func menuDidClose(_ menu: NSMenu) { controller.isMenuOpen = false }

    private func rebuildOrganizerMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false

        if !controller.isTrusted {
            let permission = NSMenuItem(title: "Accessibility Access Required", action: nil, keyEquivalent: "")
            permission.isEnabled = false
            menu.addItem(permission)

            let open = NSMenuItem(title: "Open System Settings…", action: #selector(openPrivacySettingsFromMenu), keyEquivalent: "")
            open.target = self
            menu.addItem(open)
        } else {
            let hiddenItems = controller.hiddenItems
            if hiddenItems.isEmpty {
                let empty = NSMenuItem(title: "No Hidden Items", action: nil, keyEquivalent: "")
                empty.isEnabled = false
                menu.addItem(empty)
            } else {
                for item in hiddenItems {
                    let menuItem = NSMenuItem(title: item.title, action: #selector(openHiddenItem(_:)), keyEquivalent: "")
                    menuItem.target = self
                    menuItem.representedObject = item.key.rawValue
                    menuItem.image = menuIcon(item.icon)
                    menuItem.isEnabled = !controller.isBusy && !controller.isArranging
                    menu.addItem(menuItem)
                }
                menu.addItem(.separator())

                let reveal = NSMenuItem(
                    title: controller.isRevealed ? "Hide Hidden Items" : "Reveal Hidden Items for 20 Seconds",
                    action: #selector(toggleRevealFromMenu),
                    keyEquivalent: ""
                )
                reveal.target = self
                reveal.isEnabled = !controller.isBusy && !controller.isArranging
                menu.addItem(reveal)
            }
            let arrange = NSMenuItem(title: controller.isArranging ? "Done Arranging" : "Arrange in Menu Bar…", action: #selector(toggleArrangement), keyEquivalent: "")
            arrange.target = self
            arrange.isEnabled = !controller.isBusy
            menu.addItem(arrange)
            if let message = controller.errorMessage {
                let error = NSMenuItem(title: message, action: nil, keyEquivalent: "")
                error.isEnabled = false
                menu.addItem(error)
            }
        }

        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettingsFromMenu), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)
    }

    private func updateStatusItem(enabled: Bool) {
        enableMenuItem?.state = enabled ? .on : .off
        if enabled {
            installStatusItemIfNeeded()
        } else {
            tray.close()
            removeStatusItem()
        }
    }

    private func installStatusItemIfNeeded() {
        guard statusItem == nil else { return }
        MenuBarSection.prepareSavedPositions()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "MacTools.Organizer.Menu"
        item.button?.image = statusItemImage(revealed: controller.isRevealed)
        item.button?.toolTip = "Menu Bar Organizer"
        item.button?.target = self
        item.button?.action = #selector(toggleTray(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
    }

    private func removeStatusItem() {
        if let statusItem {
            let key = "NSStatusItem Preferred Position MacTools.Organizer.Menu"
            let saved = UserDefaults.standard.object(forKey: key)
            NSStatusBar.system.removeStatusItem(statusItem)
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            self.statusItem = nil
        }
    }

    private func updateStatusItemImage(revealed: Bool) {
        statusItem?.button?.image = statusItemImage(revealed: revealed)
    }

    private func statusItemImage(revealed: Bool) -> NSImage? {
        NSImage(
            systemSymbolName: tray.isVisible ? "chevron.right" : "chevron.left",
            accessibilityDescription: "Menu Bar Organizer"
        )
    }

    private func menuIcon(_ icon: NSImage?) -> NSImage? {
        guard let icon = icon?.copy() as? NSImage else { return nil }
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }

    @objc private func openHiddenItem(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String else { return }
        controller.revealAndPress(MenuBarItemKey(rawValue: rawValue))
    }

    @objc private func toggleTray(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            tray.close()
            let menu = makeOrganizerMenu()
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY), in: sender)
            return
        }
        guard controller.isTrusted else { showSettings(); return }
        tray.toggle(relativeTo: sender, controller: controller, settings: { [weak self] in self?.showSettings() },
                    onClose: { [weak self] in
                        self?.controller.isMenuOpen = false
                        self?.updateStatusItemImage(revealed: false)
                    })
        controller.isMenuOpen = tray.isVisible
        updateStatusItemImage(revealed: false)
    }

    @objc private func toggleRevealFromMenu() {
        if controller.isRevealed {
            controller.hideNow()
        } else {
            controller.revealAll()
        }
    }

    @objc private func openPrivacySettingsFromMenu() {
        controller.requestAccess()
        controller.openPrivacySettings()
    }

    @objc private func toggleArrangement() {
        if controller.isArranging { controller.finishArrangement() }
        else { controller.beginArrangement(); showSettings() }
    }

    @objc private func toggleEnabledFromMenu() {
        controller.setEnabled(!settings.isEnabled)
    }

    @objc private func showSettingsFromMenu() {
        showSettings()
    }
}
