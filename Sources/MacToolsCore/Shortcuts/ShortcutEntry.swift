import Foundation

public enum ShortcutScope: String, Codable, Sendable {
    /// Works whichever app is in front.
    case global
    /// Works only inside one app, usually through its menus.
    case inApp
}

/// Where a shortcut comes from: macOS, Mac Tools, or one app.
public struct ShortcutSource: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        case system
        case standard
        case macTools
        case app(bundleID: String)
    }

    public let id: String
    public let name: String
    public let kind: Kind

    public init(id: String, name: String, kind: Kind) {
        self.id = id
        self.name = name
        self.kind = kind
    }

    public static let macOS = ShortcutSource(id: "macos", name: "macOS", kind: .system)
    public static let standard = ShortcutSource(id: "standard", name: "Standard", kind: .standard)
    public static let macTools = ShortcutSource(id: "mac-tools", name: "Mac Tools", kind: .macTools)

    public static func app(bundleID: String, name: String) -> ShortcutSource {
        ShortcutSource(id: bundleID, name: name, kind: .app(bundleID: bundleID))
    }
}

public struct ShortcutEntry: Identifiable, Hashable, Sendable {
    public let id: String
    public let combo: KeyCombo
    /// What the shortcut does, in a few words.
    public let action: String
    /// The group (macOS) or menu path (`File ▸ Export`).
    public let detail: String?
    public let source: ShortcutSource
    public let scope: ShortcutScope
    /// False for shortcuts the user turned off.
    public let isEnabled: Bool
    /// Found in an app's settings but shaped like a menu shortcut (⌘S), so not counted as global.
    public let isProbablyInApp: Bool
    /// An app's global shortcuts only work while it runs.
    public let isSourceRunning: Bool

    public init(
        combo: KeyCombo, action: String, detail: String? = nil, source: ShortcutSource, scope: ShortcutScope,
        isEnabled: Bool = true, isProbablyInApp: Bool = false, isSourceRunning: Bool = true
    ) {
        self.id = "\(source.id)|\(scope.rawValue)|\(detail ?? "")|\(action)|\(combo)"
        self.combo = combo
        self.action = action
        self.detail = detail
        self.source = source
        self.scope = scope
        self.isEnabled = isEnabled
        self.isProbablyInApp = isProbablyInApp
        self.isSourceRunning = isSourceRunning
    }

    /// Enabled, global, and not a menu-style shortcut: what can actually clash.
    public var isActiveGlobal: Bool {
        scope == .global && isEnabled && !isProbablyInApp
    }
}

/// Reads loosely typed property-list values without trusting their types.
enum PlistValue {
    static func int(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber:
            let double = number.doubleValue
            guard double.rounded() == double, abs(double) < 1e12 else { return nil }
            return number.intValue
        case let int as Int: return int
        default: return nil
        }
    }

    static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let bool as Bool: return bool
        case let number as NSNumber: return number.boolValue
        case let int as Int: return int != 0
        default: return nil
        }
    }

    /// Hardware key codes are 0…127.
    static func keyCode(_ value: Any?) -> UInt16? {
        guard let int = int(value), (0...0x7F).contains(int) else { return nil }
        return UInt16(int)
    }

    static func modifierBits(_ value: Any?) -> Int? {
        guard let int = int(value), int >= 0 else { return nil }
        return int
    }
}
