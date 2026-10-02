import Foundation

public enum ShortcutVerdict: Equatable, Sendable {
    /// An enabled global shortcut already uses it.
    case takenGlobally
    /// Nearly every app uses it (⌘C, ⌘Q…).
    case standard
    /// Can't work as a global shortcut; the reason is user-facing copy.
    case notUsable(String)
    /// Free globally, but some apps use it in their menus.
    case usedInApps
    /// Free among the shortcuts Mac Tools can see.
    case free
}

public struct ShortcutCheckResult: Sendable, Identifiable {
    public let combo: KeyCombo
    public let verdict: ShortcutVerdict
    public let globalOwners: [ShortcutEntry]
    public let standardMatches: [ShortcutEntry]
    public let inAppMatches: [ShortcutEntry]
    /// Turned-off macOS shortcuts and menu-style shortcuts found in app settings.
    public let inactiveMatches: [ShortcutEntry]

    public var id: KeyCombo { combo }
}

public enum ShortcutChecker {
    public static func check(_ combo: KeyCombo, in catalog: ShortcutCatalog) -> ShortcutCheckResult {
        let matches = catalog.entries.filter { $0.combo == combo }
        let globalOwners = matches.filter(\.isActiveGlobal)
        let standard = matches.filter { $0.source.kind == .standard }
        let inApp = matches.filter { $0.scope == .inApp && $0.source.kind != .standard }
        let inactive = matches.filter { $0.scope == .global && !$0.isActiveGlobal }

        let verdict: ShortcutVerdict
        if let reason = unusableReason(combo) {
            verdict = .notUsable(reason)
        } else if !globalOwners.isEmpty {
            verdict = .takenGlobally
        } else if !standard.isEmpty {
            verdict = .standard
        } else if !inApp.isEmpty || inactive.contains(where: \.isProbablyInApp) {
            verdict = .usedInApps
        } else {
            verdict = .free
        }
        return ShortcutCheckResult(
            combo: combo, verdict: verdict, globalOwners: globalOwners,
            standardMatches: standard, inAppMatches: inApp, inactiveMatches: inactive
        )
    }

    private static func unusableReason(_ combo: KeyCombo) -> String? {
        guard !KeyNames.isFunctionKey(combo.keyCode) else { return nil }
        let modifiers = combo.modifiers.subtracting(.function)
        if modifiers.isEmpty { return "Needs at least one modifier key" }
        if modifiers == [.shift] { return "Shift alone types a character" }
        return nil
    }

    /// Modifier sets that make good global shortcuts.
    static let alternativeModifierSets: [ShortcutModifiers] = [
        [.control, .option], [.control, .command], [.option, .command], [.control, .option, .command],
        [.control, .shift, .command], [.option, .shift, .command], [.control, .option, .shift],
        [.control, .option, .shift, .command],
    ]

    /// The same key with other global-friendly modifiers: free ones first, then ones only apps use.
    public static func alternatives(for combo: KeyCombo, in catalog: ShortcutCatalog) -> [ShortcutCheckResult] {
        let results = alternativeModifierSets
            .map { KeyCombo(keyCode: combo.keyCode, modifiers: $0) }
            .filter { $0 != combo }
            .map { check($0, in: catalog) }
        func rank(_ verdict: ShortcutVerdict) -> Int {
            switch verdict {
            case .free: 0
            case .usedInApps: 1
            default: 2
            }
        }
        return results.enumerated()
            .sorted { (rank($0.element.verdict), $0.offset) < (rank($1.element.verdict), $1.offset) }
            .map(\.element)
    }
}
