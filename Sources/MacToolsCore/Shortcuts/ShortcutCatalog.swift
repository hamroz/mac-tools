import Foundation

/// Every shortcut found, with clashes between global ones worked out once.
public struct ShortcutCatalog: Sendable {
    public let entries: [ShortcutEntry]
    /// Combos claimed by two or more different active global shortcuts.
    public let conflicts: [KeyCombo: [ShortcutEntry]]

    public init(entries: [ShortcutEntry]) {
        var seen = Set<String>()
        let unique = entries.filter { seen.insert($0.id).inserted }
        self.entries = unique

        var conflicts: [KeyCombo: [ShortcutEntry]] = [:]
        for (combo, owners) in Dictionary(grouping: unique.filter(\.isActiveGlobal), by: \.combo) {
            let distinctActions = Set(owners.map { "\($0.source.id)|\($0.action)" })
            if distinctActions.count > 1 { conflicts[combo] = owners }
        }
        self.conflicts = conflicts
    }

    public static let empty = ShortcutCatalog(entries: [])

    public var globalEntries: [ShortcutEntry] { entries.filter { $0.scope == .global } }
    public var inAppEntries: [ShortcutEntry] { entries.filter { $0.scope == .inApp } }

    public func isConflicted(_ entry: ShortcutEntry) -> Bool {
        entry.isActiveGlobal && conflicts[entry.combo] != nil
    }

    /// The other shortcuts an entry clashes with.
    public func clashes(with entry: ShortcutEntry) -> [ShortcutEntry] {
        guard entry.isActiveGlobal else { return [] }
        return (conflicts[entry.combo] ?? []).filter { $0.source.id != entry.source.id || $0.action != entry.action }
    }

    /// Every whitespace-separated term must appear in the action, detail, app, or keys (any case).
    public func entries(matching query: String, in scope: [ShortcutEntry]) -> [ShortcutEntry] {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !terms.isEmpty else { return scope }
        return scope.filter { entry in
            let haystack = "\(entry.action) \(entry.detail ?? "") \(entry.source.name) \(entry.combo.searchText)".lowercased()
            return terms.allSatisfy { haystack.contains($0) }
        }
    }
}
