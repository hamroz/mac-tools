import Combine
import Foundation
import MacToolsCore

@MainActor
final class MenuBarOrganizerSettings: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var hiddenKeys: Set<MenuBarItemKey>

    private let defaults: UserDefaults
    private static let enabledKey = "menuBarOrganizer.isEnabled"
    private static let hiddenItemsKey = "menuBarOrganizer.hiddenItems"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        let stored = defaults.stringArray(forKey: Self.hiddenItemsKey) ?? []
        hiddenKeys = Set(stored.map(MenuBarItemKey.init(rawValue:)))
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

    func migrate(_ legacyKey: MenuBarItemKey, to key: MenuBarItemKey) {
        guard legacyKey != key, hiddenKeys.contains(legacyKey) else { return }
        hiddenKeys.remove(legacyKey)
        hiddenKeys.insert(key)
        defaults.set(hiddenKeys.map(\.rawValue).sorted(), forKey: Self.hiddenItemsKey)
    }
}
