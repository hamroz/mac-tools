import AppKit
import Combine
import MacToolsCore
import SwiftUI

@MainActor
final class AIUsageModule: NSObject, ToolModule, NSPopoverDelegate {
    let descriptor = ToolDescriptor(
        id: "ai-usage",
        name: "AI Usage",
        summary: "How much of your Claude and Codex limits is left, one click away in the menu bar.",
        symbolName: "gauge.with.dots.needle.67percent",
        tint: .purple
    )

    var openSettings: (() -> Void)?

    let settings: AIUsageSettings
    let store: AIUsageStore
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var usageWindow: NSWindow?
    private var observers: [AnyCancellable] = []
    private var menuObservers: [AnyCancellable] = []
    private static let autosaveName = "MacTools.AIUsage"

    init(settings: AIUsageSettings = AIUsageSettings(), store: AIUsageStore? = nil) {
        self.settings = settings
        self.store = store ?? AIUsageStore(settings: settings)
        super.init()
    }

    var isShownInMenuBar: Bool { statusItem?.isVisible == true }

    func start() {
        installStatusItem()
        observers = [
            settings.$showInMenuBar.sink { [weak self] visible in
                self?.statusItem?.isVisible = visible
                if !visible { self?.popover?.performClose(nil) }
            },
            Publishers.CombineLatest3(store.$states, settings.$showPercentInMenuBar, settings.$enabledServices)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.updateStatusButton() },
        ]
        store.start()
    }

    func stop() {
        observers.removeAll()
        store.stop()
        popover?.performClose(nil)
        popover = nil
        usageWindow?.close()
        removeStatusItem()
    }

    func makeMenuItems() -> [NSMenuItem] {
        menuObservers.removeAll()
        var items: [NSMenuItem] = []
        for service in UsageServiceID.allCases {
            let item = NSMenuItem(title: service.name, action: #selector(showUsageFromMenu), keyEquivalent: "")
            item.target = self
            menuObservers.append(store.$states.combineLatest(settings.$enabledServices).sink { [weak self, weak item] states, enabled in
                item?.isHidden = !enabled.contains(service)
                item?.title = self?.menuTitle(for: service, state: states[service]) ?? service.name
            })
            items.append(item)
        }
        let show = NSMenuItem(title: "Show Usage…", action: #selector(showUsageFromMenu), keyEquivalent: "")
        show.target = self
        let refresh = NSMenuItem(title: "Refresh Usage", action: #selector(refreshFromMenu), keyEquivalent: "")
        refresh.target = self
        return items + [show, refresh]
    }

    func makeSettingsView() -> AnyView {
        AnyView(AIUsageSettingsView(store: store, settings: settings))
    }

    // MARK: Status item

    private func installStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = Self.autosaveName
        item.isVisible = settings.showInMenuBar
        if let button = item.button {
            button.image = Self.statusImage
            button.imagePosition = .imageLeading
            button.toolTip = "AI Usage"
            button.target = self
            button.action = #selector(togglePopover(_:))
        }
        statusItem = item
        updateStatusButton()
    }

    /// Removing a status item also forgets where the user placed it, so keep that.
    private func removeStatusItem() {
        guard let statusItem else { return }
        let key = "NSStatusItem Preferred Position \(Self.autosaveName)"
        let position = UserDefaults.standard.object(forKey: key)
        NSStatusBar.system.removeStatusItem(statusItem)
        if let position { UserDefaults.standard.set(position, forKey: key) }
        self.statusItem = nil
    }

    private static var statusImage: NSImage? {
        let image = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: "AI Usage")
        image?.isTemplate = true
        return image
    }

    private func updateStatusButton() {
        guard let button = statusItem?.button else { return }
        let lowest = store.activeServices.compactMap { store.state(for: $0).snapshot?.compactRemaining() }.min()
        if settings.showPercentInMenuBar, let lowest {
            button.title = " \(lowest)%"
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .medium)
        } else {
            button.title = ""
        }
        button.toolTip = store.activeServices.map { menuTitle(for: $0, state: store.state(for: $0)) }.joined(separator: "\n")
    }

    @objc private func togglePopover(_ sender: Any?) {
        if let popover, popover.isShown {
            popover.performClose(sender)
            return
        }
        guard let button = statusItem?.button else { return }
        let popover = popover ?? makePopover()
        self.popover = popover
        store.refreshIfStale()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func makePopover() -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let hosting = NSHostingController(rootView: usageView(onSettings: { [weak self] in
            self?.popover?.performClose(nil)
            self?.openSettings?()
        }))
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        return popover
    }

    private func usageView(onSettings: @escaping () -> Void) -> AIUsagePopoverView {
        AIUsagePopoverView(store: store, settings: settings, openSettings: onSettings)
    }

    // MARK: Menu commands

    /// Opens the popover, or a small window when the menu bar icon is hidden.
    @objc private func showUsageFromMenu() {
        if isShownInMenuBar {
            // Let the Mac Tools menu finish closing before the popover takes focus.
            DispatchQueue.main.async { [weak self] in self?.togglePopover(nil) }
            return
        }
        store.refreshIfStale()
        if usageWindow == nil {
            let hosting = NSHostingController(rootView: usageView(onSettings: { [weak self] in self?.openSettings?() }))
            hosting.sizingOptions = .preferredContentSize
            let window = NSWindow(contentViewController: hosting)
            window.title = "AI Usage"
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.center()
            usageWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        usageWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func refreshFromMenu() { store.refresh() }

    private func menuTitle(for service: UsageServiceID, state: UsageServiceState?) -> String {
        guard let snapshot = state?.snapshot, let window = snapshot.tightestWindow() ?? snapshot.windows.first else {
            return state?.errorMessage != nil ? "\(service.name): unavailable" : "\(service.name): checking…"
        }
        let remaining = snapshot.compactRemaining() ?? Int(window.remainingPercent)
        return "\(service.name): \(remaining)% left · \(window.title.lowercased())"
    }
}
