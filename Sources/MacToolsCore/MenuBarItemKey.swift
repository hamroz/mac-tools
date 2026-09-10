import Foundation

/// Stable identity for another app's menu bar item.
///
/// Menu bar items cannot be referenced across scans, relaunches, or app
/// updates by pointer, so identity comes from the accessibility identifier
/// when one exists and from the owning bundle identifier plus the visible
/// title otherwise.
public struct MenuBarItemKey: Hashable, Sendable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(identifier: String, bundleIdentifier: String?, title: String) {
        let identifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if !identifier.isEmpty {
            let owner = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            rawValue = owner.isEmpty ? "id:\(identifier)" : "app:\(owner)|id:\(identifier)"
            return
        }

        let bundle = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        let owner: String
        if let bundle, !bundle.isEmpty {
            owner = bundle
        } else {
            owner = "unknown"
        }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        rawValue = "app:\(owner)|\(name)"
    }
}
