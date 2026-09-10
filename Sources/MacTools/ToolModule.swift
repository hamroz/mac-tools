import AppKit

struct ToolDescriptor: Identifiable {
    let id: String
    let name: String
    let symbolName: String
}

@MainActor
protocol ToolModule: AnyObject {
    var descriptor: ToolDescriptor { get }
    func start()
    func stop()
    func makeMenuItems() -> [NSMenuItem]
    func showManager()
    func showSettings()
}

@MainActor
final class ToolRegistry {
    private(set) var modules: [any ToolModule]

    init(modules: [any ToolModule]) {
        self.modules = modules
    }

    func startAll() {
        modules.forEach { $0.start() }
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "Mac Tools")
        for module in modules {
            let heading = NSMenuItem(title: module.descriptor.name, action: nil, keyEquivalent: "")
            heading.isEnabled = false
            menu.addItem(heading)
            module.makeMenuItems().forEach(menu.addItem)
            menu.addItem(.separator())
        }
        return menu
    }

    func stopAll() {
        modules.forEach { $0.stop() }
    }
}
