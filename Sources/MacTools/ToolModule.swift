import AppKit
import Combine
import SwiftUI

struct ToolDescriptor: Identifiable {
    let id: String
    let name: String
    let summary: String
    let symbolName: String
    let tint: Color
}

@MainActor
protocol ToolModule: AnyObject {
    var descriptor: ToolDescriptor { get }
    /// Set by the registry so a tool can bring up its own page in Mac Tools Settings.
    var openSettings: (() -> Void)? { get set }
    func start()
    /// Must fully undo `start()`: the tool can be switched off while Mac Tools keeps running.
    func stop()
    func makeMenuItems() -> [NSMenuItem]
    func makeSettingsView() -> AnyView
}

@MainActor
final class ToolRegistry: ObservableObject {
    let modules: [any ToolModule]
    @Published private(set) var enabledIDs: Set<String>

    /// Called after a tool is switched on or off, so the menu bar menu can be rebuilt.
    var onChange: (() -> Void)?
    /// Called when a tool asks for its settings page.
    var onOpenSettings: ((String) -> Void)?

    private let defaults: UserDefaults
    private var isRunning = false

    init(modules: [any ToolModule], defaults: UserDefaults = .standard) {
        self.modules = modules
        self.defaults = defaults
        enabledIDs = Set(modules.map(\.descriptor.id).filter { defaults.object(forKey: Self.key(for: $0)) as? Bool ?? true })
        for module in modules {
            let id = module.descriptor.id
            module.openSettings = { [weak self] in self?.onOpenSettings?(id) }
        }
    }

    var enabledModules: [any ToolModule] {
        modules.filter { enabledIDs.contains($0.descriptor.id) }
    }

    func module(id: String) -> (any ToolModule)? {
        modules.first { $0.descriptor.id == id }
    }

    func isEnabled(_ id: String) -> Bool {
        enabledIDs.contains(id)
    }

    func setEnabled(_ enabled: Bool, for id: String) {
        guard let module = module(id: id), isEnabled(id) != enabled else { return }
        defaults.set(enabled, forKey: Self.key(for: id))
        if enabled {
            enabledIDs.insert(id)
            if isRunning { module.start() }
        } else {
            enabledIDs.remove(id)
            if isRunning { module.stop() }
        }
        onChange?()
    }

    func startAll() {
        isRunning = true
        enabledModules.forEach { $0.start() }
    }

    func stopAll() {
        enabledModules.forEach { $0.stop() }
        isRunning = false
    }

    /// Tool sections for the menu bar menu. App-wide commands are appended by the caller.
    func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "Mac Tools")
        for module in enabledModules {
            let heading = NSMenuItem(title: module.descriptor.name, action: nil, keyEquivalent: "")
            heading.isEnabled = false
            menu.addItem(heading)
            module.makeMenuItems().forEach(menu.addItem)
            menu.addItem(.separator())
        }
        return menu
    }

    private static func key(for id: String) -> String { "tools.\(id).isEnabled" }
}
