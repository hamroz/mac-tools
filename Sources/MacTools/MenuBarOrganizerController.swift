import AppKit
import MacToolsCore

@MainActor
final class MenuBarOrganizerController: ObservableObject {
    @Published private(set) var items: [MenuBarItemSnapshot] = []
    @Published private(set) var isTrusted: Bool
    @Published private(set) var isRevealed = false
    @Published private(set) var isArranging = false
    @Published private(set) var isBusy = false
    @Published private(set) var errorMessage: String?

    var pressDelay: Duration = .milliseconds(250)
    var layoutDelay: Duration = .milliseconds(250)
    var revealDuration: Duration = .seconds(20)
    var isMenuOpen = false
    var beforeCollapse: (([MenuBarItemSnapshot]) async -> Void)?

    private let scanner: any MenuBarItemScanning
    private let settings: MenuBarOrganizerSettings
    let section: any MenuBarSectionControlling
    private var reconciled: [MenuBarItemKey: String] = [:]
    private var temporarilyVisible: Set<MenuBarItemKey> = []
    private var returnAnchors: [MenuBarItemKey: (key: MenuBarItemKey, before: Bool)] = [:]
    private var lastActivation = "None"
    private var operationTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var rehideTask: Task<Void, Never>?
    private var generation = 0
    private var diagnosticsWindow: NSWindow?

    init(scanner: any MenuBarItemScanning, settings: MenuBarOrganizerSettings,
         section: any MenuBarSectionControlling = MenuBarSection()) {
        self.scanner = scanner
        self.settings = settings
        self.section = section
        isTrusted = scanner.isTrusted
    }

    var hiddenItems: [MenuBarItemSnapshot] { items.filter { settings.isHidden($0.key) } }

    func start() {
        if settings.isEnabled {
            section.install()
            startPolling()
        }
        refresh()
    }

    func stop() {
        generation += 1
        operationTask?.cancel()
        operationTask = nil
        pollTask?.cancel()
        pollTask = nil
        cancelRehide()
        // Removing our spacer restores access even if Accessibility was revoked.
        section.remove()
        isBusy = false
        isArranging = false
        isRevealed = false
        temporarilyVisible.removeAll()
        returnAnchors.removeAll()
        reconciled.removeAll()
    }

    func setEnabled(_ enabled: Bool) {
        if !enabled { stop() }
        settings.setEnabled(enabled)
        errorMessage = nil
        if enabled {
            section.install()
            startPolling()
            refresh()
        }
    }

    func refresh() {
        guard !isBusy, !isMenuOpen else { return }
        scanItems()
        guard settings.isEnabled, isTrusted, !isRevealed, !isArranging, !scanner.isInteracting else { return }
        if items.contains(where: { reconciled[$0.key] != $0.instanceID }) {
            perform { controller in try await controller.reconcileAndCollapse() }
        }
    }

    func setHidden(_ hidden: Bool, for key: MenuBarItemKey) {
        guard !isBusy else { return }
        if !settings.isEnabled {
            settings.setHidden(hidden, for: key)
            return
        }
        guard let item = items.first(where: { $0.key == key }), item.canMove else {
            errorMessage = MenuBarOperationError.immovable.localizedDescription
            return
        }
        perform { controller in
            try await controller.expand()
            try await controller.place(key, hidden: hidden)
            try Task.checkCancellation()
            // Commit only after the observed position crosses the divider.
            controller.settings.setHidden(hidden, for: key)
            controller.reconciled[key] = item.instanceID
            if !controller.isArranging { try await controller.reconcileAndCollapse() }
        }
    }

    func revealAll() {
        guard settings.isEnabled, !isBusy else { return }
        cancelRehide()
        perform { controller in
            try await controller.expand()
            controller.isRevealed = true
            controller.scheduleRehide()
        }
    }

    func revealAndPress(_ key: MenuBarItemKey) {
        guard settings.isEnabled, !isBusy else { return }
        cancelRehide()
        perform { controller in
            // NSMenu must finish dismissing before a click is delivered to another app.
            try await Task.sleep(for: controller.pressDelay)
            if !controller.section.isCollapsed { try await controller.expand() }
            else { controller.scanItems() }
            guard controller.items.contains(where: { $0.key == key }) else { throw MenuBarOperationError.unavailable }
            if controller.settings.isHidden(key) {
                let peers = controller.hiddenItems
                if let index = peers.firstIndex(where: { $0.key == key }) {
                    if peers.indices.contains(index + 1) { controller.returnAnchors[key] = (peers[index + 1].key, true) }
                    else if index > 0 { controller.returnAnchors[key] = (peers[index - 1].key, false) }
                }
                try await controller.place(key, hidden: false)
                controller.temporarilyVisible.insert(key)
            }
            try Task.checkCancellation()
            controller.isRevealed = !controller.section.isCollapsed
            let previous = controller.menuWindowDescriptions()
            try await controller.scanner.press(key)
            try await Task.sleep(for: .milliseconds(200))
            let added = controller.menuWindowDescriptions().subtracting(previous)
            controller.lastActivation = "\(key.rawValue): new native windows: \(added.sorted().joined(separator: "; "))"
            controller.scheduleRehide()
        }
    }

    func hideNow() {
        guard settings.isEnabled, !isBusy, !isArranging else { return }
        cancelRehide()
        perform { controller in
            if controller.section.isCollapsed, !controller.temporarilyVisible.isEmpty {
                for key in controller.temporarilyVisible { try await controller.restoreTemporaryItem(key) }
                controller.temporarilyVisible.removeAll()
                controller.returnAnchors.removeAll()
            } else { try await controller.reconcileAndCollapse() }
        }
    }

    func beginArrangement() {
        guard settings.isEnabled, !isBusy else { return }
        cancelRehide()
        perform { controller in
            try await controller.expand()
            controller.isRevealed = true
            controller.isArranging = true
        }
    }

    func finishArrangement() {
        guard isArranging, !isBusy, !scanner.isInteracting else { return }
        scanItems()
        guard let divider = section.dividerFrame else { return }
        for item in items where item.canMove {
            settings.setHidden(item.frame.midX < divider.midX, for: item.key)
            reconciled[item.key] = item.instanceID
        }
        temporarilyVisible.removeAll()
        isArranging = false
        hideNow()
    }

    /// Reorders adjacent items within a section; AppKit persists the physical order.
    func moveItem(_ key: MenuBarItemKey, earlier: Bool) {
        guard settings.isEnabled, !isBusy else { return }
        let peers = items.filter { settings.isHidden($0.key) == settings.isHidden(key) && $0.canMove }
        guard let index = peers.firstIndex(where: { $0.key == key }) else { return }
        let neighborIndex = index + (earlier ? -1 : 1)
        guard peers.indices.contains(neighborIndex) else { return }
        let neighborKey = peers[neighborIndex].key
        perform { controller in
            try await controller.expand()
            guard let neighbor = controller.items.first(where: { $0.key == neighborKey }) else { throw MenuBarOperationError.unavailable }
            let x = earlier ? neighbor.frame.minX - 2 : neighbor.frame.maxX + 2
            try await controller.scanner.move(key, to: CGPoint(x: x, y: neighbor.frame.midY))
            try await Task.sleep(for: controller.layoutDelay)
            controller.scanItems()
            guard let moved = controller.items.first(where: { $0.key == key }),
                  let other = controller.items.first(where: { $0.key == neighborKey }),
                  earlier ? moved.frame.midX < other.frame.midX : moved.frame.midX > other.frame.midX else {
                throw MenuBarOperationError.moveFailed
            }
            if !controller.isArranging { try await controller.reconcileAndCollapse() }
        }
    }

    func requestAccess() { scanner.requestAccess(); refreshAccessStatus() }
    func openPrivacySettings() { scanner.openPrivacySettings() }
    func refreshAccessStatus() { refresh() }

    func showDiagnostics() {
        scanItems()
        let rows = items.map { "\($0.title): pid=\($0.processIdentifier) window=\($0.windowID.map(String.init) ?? "NONE") ax=\(NSStringFromRect($0.frame))" }
        let system = AXUIElementCreateSystemWide()
        let windows = MenuBarWindowCatalog.items().map { window in
            var hit: AXUIElement?
            let result = AXUIElementCopyElementAtPosition(system, Float(window.frame.midX), Float(window.frame.midY), &hit)
            var pid: pid_t = 0
            if let hit { AXUIElementGetPid(hit, &pid) }
            return "pid=\(window.pid) id=\(window.id) name=\(window.title) bounds=\(NSStringFromRect(window.frame)) hitPID=\(pid) hitResult=\(result.rawValue)"
        }
        let text = "App: \(Bundle.main.bundleURL.path)\nAccessibility: \(isTrusted)\nDivider: \(section.dividerFrame.map(NSStringFromRect) ?? "NONE") collapsed=\(section.isCollapsed)\nLast activation: \(lastActivation)\n\nITEMS\n" + rows.joined(separator: "\n") + "\n\nSTATUS WINDOWS\n" + windows.joined(separator: "\n")
        if diagnosticsWindow == nil {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 740, height: 550), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Menu Bar Diagnostics"
            window.isReleasedWhenClosed = false
            window.center()
            diagnosticsWindow = window
        }
        let view = NSTextView(frame: CGRect(x: 0, y: 0, width: 720, height: 2000))
        view.isEditable = false
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.string = text
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = view
        diagnosticsWindow?.contentView = scroll
        diagnosticsWindow?.makeKeyAndOrderFront(nil)
    }

    private func scanItems() {
        isTrusted = scanner.isTrusted
        guard isTrusted else {
            items = []
            section.setCollapsed(false)
            reconciled.removeAll()
            return
        }
        let scanned = scanner.scan()
        if items.count != scanned.count || !zip(items, scanned).allSatisfy({ $0.hasSamePresentation(as: $1) }) {
            items = scanned
        }
        for item in items {
            if let legacy = item.legacyKey { settings.migrate(legacy, to: item.key) }
        }
        let keys = Set(items.map(\.key))
        reconciled = reconciled.filter { keys.contains($0.key) }
    }

    private func expand() async throws {
        guard settings.isEnabled, scanner.isTrusted else { throw MenuBarOperationError.permission }
        section.setCollapsed(false)
        try await Task.sleep(for: layoutDelay)
        try Task.checkCancellation()
        scanItems()
        guard section.dividerFrame != nil else { throw MenuBarOperationError.layout }
        try await section.repairPlacement()
    }

    private func place(_ key: MenuBarItemKey, hidden: Bool) async throws {
        guard let item = items.first(where: { $0.key == key }), let divider = section.dividerFrame else {
            throw MenuBarOperationError.unavailable
        }
        if (item.frame.midX < divider.midX) == hidden { return }
        guard item.canMove else { throw MenuBarOperationError.immovable }
        let destination = CGPoint(x: hidden ? divider.minX - 2 : divider.maxX + 2, y: divider.midY)
        try await scanner.move(key, to: destination)
        try await Task.sleep(for: layoutDelay)
        try Task.checkCancellation()
        scanItems()
        guard let moved = items.first(where: { $0.key == key }), let boundary = section.dividerFrame,
              (moved.frame.midX < boundary.midX) == hidden else { throw MenuBarOperationError.moveFailed }
    }

    private func reconcileAndCollapse() async throws {
        try await expand()
        for key in temporarilyVisible { try await restoreTemporaryItem(key) }
        // Refresh after every move: macOS shifts all neighboring icons when one moves.
        // Inserting left of the divider appends; inserting right prepends.
        // Walk visible items backwards so startup preserves their original order.
        let movable = items.filter(\.canMove)
        let keys = movable.filter { settings.isHidden($0.key) }.map(\.key) +
            movable.filter { !settings.isHidden($0.key) }.reversed().map(\.key)
        for key in keys {
            try Task.checkCancellation()
            try await place(key, hidden: settings.isHidden(key))
            if let item = items.first(where: { $0.key == key }) { reconciled[key] = item.instanceID }
        }
        temporarilyVisible.removeAll()
        returnAnchors.removeAll()
        for item in items { reconciled[item.key] = item.instanceID }
        if !hiddenItems.isEmpty {
            await beforeCollapse?(hiddenItems)
            try Task.checkCancellation()
            section.setCollapsed(true)
            guard section.isCollapsed else { throw MenuBarOperationError.layout }
        }
        isRevealed = false
    }

    private func perform(_ operation: @escaping @MainActor (MenuBarOrganizerController) async throws -> Void) {
        guard !isBusy else { return }
        cancelRehide()
        errorMessage = nil
        isBusy = true
        generation += 1
        let expectedGeneration = generation
        operationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == expectedGeneration { self.isBusy = false; self.operationTask = nil }
            }
            do {
                try await operation(self)
            } catch is CancellationError {
                // stop() owns cleanup. A stale task must not alter a later session.
            } catch {
                guard self.generation == expectedGeneration else { return }
                self.section.setCollapsed(false)
                self.isRevealed = true
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func restoreTemporaryItem(_ key: MenuBarItemKey) async throws {
        if let anchor = returnAnchors[key], settings.isHidden(anchor.key),
           let neighbor = items.first(where: { $0.key == anchor.key }),
           let divider = section.dividerFrame, neighbor.frame.midX < divider.midX {
            let x = anchor.before ? neighbor.frame.minX - 2 : neighbor.frame.maxX + 2
            try await scanner.move(key, to: CGPoint(x: x, y: neighbor.frame.midY))
            try await Task.sleep(for: layoutDelay)
            scanItems()
        }
        try await place(key, hidden: true)
    }

    private func menuWindowDescriptions() -> Set<String> {
        let owners = Set(items.filter { temporarilyVisible.contains($0.key) }.flatMap { [$0.processIdentifier, $0.hostProcessIdentifier] })
        let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return Set(rows.compactMap { row in
            guard let pid = row[kCGWindowOwnerPID as String] as? Int32, owners.contains(pid),
                  let id = row[kCGWindowNumber as String] as? UInt32,
                  let level = row[kCGWindowLayer as String] as? Int,
                  let bounds = row[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.height > 45 else { return nil }
            return "pid=\(pid) window=\(id) level=\(level) frame=\(NSStringFromRect(frame))"
        })
    }

    private func scheduleRehide() {
        cancelRehide()
        let duration = revealDuration
        rehideTask = Task { [weak self] in
            do { try await Task.sleep(for: duration) } catch { return }
            while !Task.isCancelled {
                guard let self, self.settings.isEnabled, !self.isArranging else { return }
                // Do not collapse while the user operates an app menu or holds a button.
                if !self.isBusy, !self.isMenuOpen, !self.scanner.isInteracting,
                   !self.scannerHasOpenMenu() {
                    self.hideNow()
                    return
                }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    private func scannerHasOpenMenu() -> Bool {
        // Window metadata needs no Screen Recording permission. Keep popovers open
        // while their app displays a window above the status bar's window level.
        let owners = Set(items.filter { temporarilyVisible.contains($0.key) }.flatMap { [$0.processIdentifier, $0.hostProcessIdentifier] })
        guard !owners.isEmpty,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        return windows.contains {
            guard let pid = $0[kCGWindowOwnerPID as String] as? Int32,
                  let level = $0[kCGWindowLayer as String] as? Int else { return false }
            return owners.contains(pid) && level > Int(CGWindowLevelForKey(.statusWindow))
        }
    }

    private func cancelRehide() { rehideTask?.cancel(); rehideTask = nil }

    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                self?.refresh()
            }
        }
    }
}
