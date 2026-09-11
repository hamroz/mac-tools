import AppKit
import MacToolsCore

/// Metadata survives the status window being removed or its source app quitting.
struct MenuBarRecoveryItem: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let appName: String?
    let bundleIdentifier: String?
    var key: MenuBarItemKey { MenuBarItemKey(rawValue: id) }

    var systemSettingID: String? {
        guard bundleIdentifier == "com.apple.controlcenter" else { return nil }
        let token = id.components(separatedBy: CharacterSet.alphanumerics.inverted).joined().lowercased()
        let controls = ["nowPlaying", "screenMirroring", "keyboardBrightness", "timeMachine",
                        "userSwitcher", "bluetooth", "airdrop", "battery", "display", "focus",
                        "sound", "wifi", "weather", "timer", "vpn"]
        return controls.first { token.hasSuffix($0.lowercased()) }.map { "controlcenter-\($0)-id" }
    }

    var recoveryIdentity: String { systemSettingID ?? id }
    var displayName: String {
        if let systemSettingID,
           let common = Self.commonSystemItems.first(where: { $0.systemSettingID == systemSettingID }) { return common.title }
        return bundleIdentifier == "com.apple.controlcenter" ? title : (appName ?? title)
    }

    init(_ item: MenuBarItemSnapshot) {
        id = item.id; title = item.title; appName = item.appName; bundleIdentifier = item.bundleIdentifier
    }

    init(id: String, title: String, appName: String?, bundleIdentifier: String?) {
        self.id = id; self.title = title; self.appName = appName; self.bundleIdentifier = bundleIdentifier
    }

    // Available even when these controls were removed before this version ran.
    static let commonSystemItems = ["Sound", "NowPlaying", "AirDrop"].map { name in
        MenuBarRecoveryItem(id: "system:\(name)", title: name == "NowPlaying" ? "Now Playing" : name,
                            appName: "Control Center", bundleIdentifier: "com.apple.controlcenter")
    }

    @MainActor
    static func legacy(_ key: MenuBarItemKey) -> Self? {
        guard key.rawValue.hasPrefix("app:"), let end = key.rawValue.firstIndex(of: "|") else { return nil }
        let bundleID = String(key.rawValue[key.rawValue.index(key.rawValue.startIndex, offsetBy: 4)..<end])
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        let name = url?.deletingPathExtension().lastPathComponent ?? bundleID
        return Self(id: key.rawValue, title: name, appName: name, bundleIdentifier: bundleID)
    }
}

@MainActor
protocol MenuBarItemRecovering {
    func restore(_ item: MenuBarRecoveryItem) async throws -> String
    func openSettings()
}

/// Uses the same controls the user sees in System Settings, not private preference
/// files or a Control Center reset. Matching is exact and changes only one item.
@MainActor
final class MenuBarItemRecovery: MenuBarItemRecovering {
    private(set) var lastDiagnostics = "None"
    private let settingsURL = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension")!
    private let alwaysLabels = ["Always Show", "Show Always", "Always"]

    func openSettings() { NSWorkspace.shared.open(settingsURL) }

    func restore(_ item: MenuBarRecoveryItem) async throws -> String {
        guard AXIsProcessTrusted() else { throw MenuBarOperationError.permission }
        openSettings()
        let labels = applicationLabels(for: item)
        lastDiagnostics = "Restoring \(item.id)"
        var target: AXUIElement?
        var settingsApp: AXUIElement?
        for _ in 0..<30 {
            try Task.checkCancellation()
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first {
                let app = AXUIElementCreateApplication(running.processIdentifier)
                AXUIElementSetMessagingTimeout(app, 0.15)
                settingsApp = app
                let nodes = descendants(app)
                let candidates = nodes.filter { element in
                    guard [kAXCheckBoxRole, "AXSwitch"].contains(string(element, kAXRoleAttribute)) else { return false }
                    if let identifier = item.systemSettingID { return string(element, kAXIdentifierAttribute) == identifier }
                    return !controlLabels(element).isDisjoint(with: labels)
                }
                lastDiagnostics = "\(item.id): matching controls=\(candidates.count)\n" + nodes.filter {
                    !controlLabels($0).isDisjoint(with: labels) || item.systemSettingID == string($0, kAXIdentifierAttribute)
                }.map {
                    "role=\(string($0, kAXRoleAttribute)) subrole=\(string($0, kAXSubroleAttribute)) labels=\(controlLabels($0).sorted()) value=\(String(describing: value($0, kAXValueAttribute)))"
                }.joined(separator: "\n")
                if candidates.count == 1 { target = candidates[0]; break }
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        guard let target, let settingsApp else { throw RecoveryError.unavailable(item.displayName) }
        guard let enabled = isEnabled(target) else { throw RecoveryError.unavailable(item.displayName) }
        // A missing app icon can have an allowed but stale hosted window. Cycling
        // only this app's allow switch gives the scanner a fresh window to verify.
        if enabled && item.systemSettingID == nil {
            _ = AXUIElementPerformAction(target, kAXPressAction as CFString)
            try await Task.sleep(for: .milliseconds(200))
            guard isEnabled(target) == false else { throw RecoveryError.unavailable(item.displayName) }
        }
        if !enabled || item.systemSettingID == nil {
            _ = AXUIElementPerformAction(target, kAXPressAction as CFString)
            var observed = false
            for _ in 0..<12 {
                try await Task.sleep(for: .milliseconds(100))
                if isEnabled(target) == true { observed = true; break }
            }
            guard observed else { throw RecoveryError.unavailable(item.displayName) }
        }

        // A disabled "When Active" control can remain invisible after enabling.
        // Explicit recovery makes Sound/Now Playing continuously available.
        if let identifier = item.systemSettingID,
           ["focus", "screenMirroring", "display", "sound", "nowPlaying", "timer"].contains(where: { identifier == "controlcenter-\($0)-id" }) {
            try await Task.sleep(for: .milliseconds(150))
            if let popup = descendants(settingsApp).first(where: {
                string($0, kAXRoleAttribute) == kAXPopUpButtonRole && string($0, kAXIdentifierAttribute) == identifier
            }) {
                let current = string(popup, kAXValueAttribute)
                if !alwaysLabels.contains(current) {
                    _ = AXUIElementPerformAction(popup, kAXPressAction as CFString)
                    var option: AXUIElement?
                    for _ in 0..<12 {
                        try await Task.sleep(for: .milliseconds(100))
                        option = descendants(popup).first {
                            string($0, kAXRoleAttribute) == kAXMenuItemRole &&
                            alwaysLabels.contains(string($0, kAXTitleAttribute))
                        }
                        if option != nil { break }
                    }
                    guard let option else {
                        for menu in descendants(popup) where string(menu, kAXRoleAttribute) == kAXMenuRole {
                            _ = AXUIElementPerformAction(menu, kAXCancelAction as CFString)
                        }
                        throw RecoveryError.chooseAlways(item.displayName)
                    }
                    _ = AXUIElementPerformAction(option, kAXPressAction as CFString)
                    try await Task.sleep(for: .milliseconds(200))
                    guard alwaysLabels.contains(string(popup, kAXValueAttribute)) else {
                        throw RecoveryError.chooseAlways(item.displayName)
                    }
                }
            }
        } else if let bundleID = item.bundleIdentifier,
                  NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty,
                  let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
        return "\(item.displayName) is enabled in macOS. Its saved Hide/Show choice applies when the icon appears."
    }

    private func applicationLabels(for item: MenuBarRecoveryItem) -> Set<String> {
        var labels = Set([item.appName, item.title].compactMap { $0 })
        if let id = item.bundleIdentifier, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            labels.insert(url.deletingPathExtension().lastPathComponent)
            if let bundle = Bundle(url: url) {
                for key in ["CFBundleName", "CFBundleDisplayName"] {
                    if let name = bundle.object(forInfoDictionaryKey: key) as? String { labels.insert(name) }
                }
            }
        }
        return labels
    }

    private func controlLabels(_ element: AXUIElement) -> Set<String> {
        var labels = Set([kAXTitleAttribute, kAXDescriptionAttribute].map { string(element, $0) }.filter { !$0.isEmpty })
        if let linked = value(element, kAXTitleUIElementAttribute), CFGetTypeID(linked) == AXUIElementGetTypeID() {
            let titleElement = linked as! AXUIElement
            for attribute in [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute] {
                let label = string(titleElement, attribute)
                if !label.isEmpty { labels.insert(label) }
            }
        }
        return labels
    }

    private func isEnabled(_ element: AXUIElement) -> Bool? {
        let raw = value(element, kAXValueAttribute)
        if let number = raw as? NSNumber { return number.boolValue }
        switch (raw as? String)?.lowercased() {
        case "1", "on", "true": return true
        case "0", "off", "false": return false
        default: return nil
        }
    }

    private func descendants(_ root: AXUIElement) -> [AXUIElement] {
        var queue = [root]
        var index = 0
        while index < queue.count && queue.count < 700 {
            let element = queue[index]
            index += 1
            queue.append(contentsOf: value(element, kAXChildrenAttribute) as? [AXUIElement] ?? [])
        }
        return queue
    }

    private func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }
    private func string(_ element: AXUIElement, _ attribute: String) -> String { value(element, attribute) as? String ?? "" }

    private enum RecoveryError: LocalizedError {
        case unavailable(String), chooseAlways(String)
        var errorDescription: String? {
            switch self {
            case .unavailable(let name): "Turn on \(name) in System Settings → Menu Bar. If it is already allowed, enable its menu bar icon in the app's own settings, then Refresh."
            case .chooseAlways(let name): "\(name) is enabled. Choose Always Show beside it in the open Menu Bar settings to make the icon available while inactive."
            }
        }
    }
}
