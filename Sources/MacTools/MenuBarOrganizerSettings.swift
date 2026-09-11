import Combine
import Foundation
import MacToolsCore

@MainActor
final class MenuBarOrganizerSettings: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var hiddenKeys: Set<MenuBarItemKey>
    @Published private(set) var rememberedItems: [MenuBarRecoveryItem]

    private let defaults: UserDefaults
    private static let enabledKey = "menuBarOrganizer.isEnabled"
    private static let hiddenItemsKey = "menuBarOrganizer.hiddenItems"
    private static let rememberedItemsKey = "menuBarOrganizer.rememberedItems"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        let stored = defaults.stringArray(forKey: Self.hiddenItemsKey) ?? []
        hiddenKeys = Set(stored.map(MenuBarItemKey.init(rawValue:)))
        rememberedItems = defaults.data(forKey: Self.rememberedItemsKey)
            .flatMap { try? JSONDecoder().decode([MenuBarRecoveryItem].self, from: $0) } ?? []
        let known = Set(rememberedItems.map(\.id))
        rememberedItems += hiddenKeys.filter { !known.contains($0.rawValue) }.compactMap(MenuBarRecoveryItem.legacy)
    }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
    }

    func setHidden(_ hidden: Bool, for key: MenuBarItemKey) {
        guard hiddenKeys.contains(key) != hidden else { return }
        if hidden {
            hiddenKeys.insert(key)
        } else {
            hiddenKeys.remove(key)
        }
        defaults.set(hiddenKeys.map(\.rawValue).sorted(), forKey: Self.hiddenItemsKey)
    }

    func isHidden(_ key: MenuBarItemKey) -> Bool {
        hiddenKeys.contains(key)
    }

    func remember(_ items: [MenuBarItemSnapshot]) {
        var catalog = Dictionary(rememberedItems.map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
        for item in items { catalog[item.id] = MenuBarRecoveryItem(item) }
        let updated = catalog.values.sorted { $0.id < $1.id }
        guard updated != rememberedItems else { return }
        rememberedItems = updated
        if let data = try? JSONEncoder().encode(updated) { defaults.set(data, forKey: Self.rememberedItemsKey) }
    }

    func migrate(_ legacyKey: MenuBarItemKey, to key: MenuBarItemKey) {
        guard legacyKey != key, hiddenKeys.contains(legacyKey) else { return }
        hiddenKeys.remove(legacyKey)
        hiddenKeys.insert(key)
        defaults.set(hiddenKeys.map(\.rawValue).sorted(), forKey: Self.hiddenItemsKey)
    }
}
