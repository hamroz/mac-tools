import Foundation

/// One menu item with a shortcut, read from an app's menu bar.
public struct MenuShortcut: Codable, Hashable, Sendable {
    /// Menus leading to the item, e.g. `["File", "Export"]`.
    public let path: [String]
    public let title: String
    public let combo: KeyCombo
    public let isEnabled: Bool

    public init(path: [String], title: String, combo: KeyCombo, isEnabled: Bool) {
        self.path = path
        self.title = title
        self.combo = combo
        self.isEnabled = isEnabled
    }
}

/// An app's menu shortcuts as of one capture; kept so apps that aren't running still show.
public struct CapturedApp: Codable, Hashable, Sendable {
    public let bundleID: String
    public let name: String
    public let capturedAt: Date
    public let items: [MenuShortcut]

    public init(bundleID: String, name: String, capturedAt: Date, items: [MenuShortcut]) {
        self.bundleID = bundleID
        self.name = name
        self.capturedAt = capturedAt
        self.items = items
    }

    public func entries(isRunning: Bool) -> [ShortcutEntry] {
        let source = ShortcutSource.app(bundleID: bundleID, name: name)
        return items.map { item in
            ShortcutEntry(
                combo: item.combo, action: item.title, detail: item.path.joined(separator: " ▸ "),
                source: source, scope: .inApp, isSourceRunning: isRunning
            )
        }
    }
}

/// Stores captured menus as JSON, keyed by bundle ID.
public final class MenuShortcutCacheStore: @unchecked Sendable {
    public let url: URL
    private let fileManager = FileManager.default

    public init(url: URL = MenuShortcutCacheStore.defaultURL) {
        self.url = url
    }

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("Mac Tools", isDirectory: true)
            .appendingPathComponent("Shortcuts", isDirectory: true)
            .appendingPathComponent("menu-shortcuts.json")
    }

    /// A missing or unreadable file is an empty cache; the next capture overwrites it.
    public func load() -> [String: CapturedApp] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: CapturedApp].self, from: data)) ?? [:]
    }

    public func save(_ apps: [String: CapturedApp]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(apps)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    public func forget() {
        try? fileManager.removeItem(at: url)
    }
}
