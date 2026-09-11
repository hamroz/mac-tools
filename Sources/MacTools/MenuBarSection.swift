import AppKit

@MainActor
protocol MenuBarSectionControlling: AnyObject {
    var dividerFrame: CGRect? { get }
    var isCollapsed: Bool { get }
    func install()
    func repairPlacement() async throws
    func setCollapsed(_ collapsed: Bool)
    func remove()
}

/// Expanding our own status item makes macOS overflow the items to its left.
/// There is no supported API for changing another application's NSStatusItem visibility.
@MainActor
final class MenuBarSection: MenuBarSectionControlling {
    private var statusItem: NSStatusItem?
    var accessButtonFrame: (() -> CGRect?)?
    private(set) var isCollapsed = false
    private(set) var revealTransitions = 0
    private let autosaveName = "MacTools.Organizer.Divider"

    static func prepareSavedPositions(defaults: UserDefaults = .standard) {
        let menuKey = "NSStatusItem Preferred Position MacTools.Organizer.Menu"
        let dividerKey = "NSStatusItem Preferred Position MacTools.Organizer.Divider"
        let menu = (defaults.object(forKey: menuKey) as? NSNumber)?.doubleValue ?? 0
        let divider = (defaults.object(forKey: dividerKey) as? NSNumber)?.doubleValue ?? menu + 28
        // AppKit stores distance from the right edge. Larger values go LEFT.
        if divider < menu + 20 {
            defaults.set(min(menu, divider), forKey: menuKey)
            defaults.set(max(menu, divider) + (abs(menu - divider) < 20 ? 28 : 0), forKey: dividerKey)
        } else {
            defaults.set(menu, forKey: menuKey)
            defaults.set(divider, forKey: dividerKey)
        }
    }

    var dividerFrame: CGRect? {
        guard let window = statusItem?.button?.window else { return nil }
        return MenuBarCoordinates.quartzFrame(window.frame)
    }

    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: 16)
        item.autosaveName = autosaveName
        item.button?.title = "│"
        item.button?.toolTip = "Command-drag items left of this divider to hide them"
        item.button?.setAccessibilityLabel("Hidden items divider")
        statusItem = item
    }

    func repairPlacement() async throws {
        guard let divider = dividerFrame, let access = accessButtonFrame?(),
              let window = statusItem?.button?.window else { throw MenuBarOperationError.layout }
        guard divider.maxX > access.minX + 2 else { return }
        let host = MenuBarWindowCatalog.items().first { $0.title == autosaveName }
        try await MenuBarEventDriver.move(windowID: host?.id ?? CGWindowID(window.windowNumber),
                                         pid: host?.pid ?? ProcessInfo.processInfo.processIdentifier,
                                         from: divider, to: CGPoint(x: access.minX - 2, y: access.midY))
        try await Task.sleep(for: .milliseconds(200))
        guard let updated = dividerFrame, let menu = accessButtonFrame?(), updated.maxX <= menu.minX + 2 else {
            throw MenuBarOperationError.layout
        }
    }

    func setCollapsed(_ collapsed: Bool) {
        guard let item = statusItem else { return }
        if isCollapsed && !collapsed { revealTransitions += 1 }
        if collapsed {
            guard let divider = dividerFrame, let access = accessButtonFrame?(),
                  divider.maxX <= access.minX + 2 else { return }
        }
        isCollapsed = collapsed
        // Bound the spacer to the connected display widths. Huge fixed lengths can
        // cause excessive backing allocations on newer releases of macOS.
        item.button?.title = collapsed ? "" : "│"
        item.button?.isEnabled = !collapsed
        item.length = collapsed ? (NSScreen.screens.map { $0.frame.width }.max() ?? 1920) + 100 : 16
    }

    func remove() {
        setCollapsed(false)
        guard let statusItem else { return }
        // AppKit clears the saved position when an item is explicitly removed.
        let key = "NSStatusItem Preferred Position \(autosaveName)"
        let position = UserDefaults.standard.object(forKey: key)
        NSStatusBar.system.removeStatusItem(statusItem)
        if let position { UserDefaults.standard.set(position, forKey: key) }
        self.statusItem = nil
    }
}
