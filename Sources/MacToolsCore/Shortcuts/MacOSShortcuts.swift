import Foundation

/// macOS's own shortcuts: the configurable ones in `com.apple.symbolichotkeys`,
/// fixed system ones, and the standard shortcuts nearly every app uses.
public enum MacOSShortcuts {
    private struct Default {
        let name: String
        let group: String
        let combo: KeyCombo?
        let isEnabled: Bool
    }

    private static func combo(_ keyCode: UInt16, _ modifiers: ShortcutModifiers) -> KeyCombo {
        KeyCombo(keyCode: keyCode, modifiers: modifiers)
    }

    /// The symbolic hotkey plist lists only shortcuts that were changed; everything else is this default.
    private static let defaults: [Int: Default] = {
        var table: [Int: Default] = [:]
        func add(_ id: Int, _ name: String, _ group: String, _ combo: KeyCombo?, enabled: Bool = true) {
            table[id] = Default(name: name, group: group, combo: combo, isEnabled: enabled)
        }
        let keyboard = "Keyboard Navigation"
        add(12, "Turn keyboard access on or off", keyboard, combo(122, [.control]))
        add(7, "Move focus to the menu bar", keyboard, combo(120, [.control]))
        add(8, "Move focus to the Dock", keyboard, combo(99, [.control]))
        add(9, "Move focus to active or next window", keyboard, combo(118, [.control]))
        add(10, "Move focus to window toolbar", keyboard, combo(96, [.control]))
        add(11, "Move focus to floating window", keyboard, combo(97, [.control]))
        add(13, "Change the way Tab moves focus", keyboard, combo(98, [.control]))
        add(57, "Move focus to status menus", keyboard, combo(100, [.control]))
        add(27, "Move focus to next window", keyboard, combo(50, [.command]))

        let accessibility = "Accessibility"
        add(15, "Turn zoom on or off", accessibility, combo(28, [.option, .command]), enabled: false)
        add(17, "Zoom in", accessibility, combo(24, [.option, .command]), enabled: false)
        add(19, "Zoom out", accessibility, combo(27, [.option, .command]), enabled: false)
        add(23, "Turn image smoothing on or off", accessibility, combo(42, [.option, .command]), enabled: false)
        add(21, "Invert colors", accessibility, combo(28, [.control, .option, .command]), enabled: false)
        add(25, "Increase contrast", accessibility, combo(47, [.control, .option, .command]), enabled: false)
        add(26, "Decrease contrast", accessibility, combo(43, [.control, .option, .command]), enabled: false)
        add(59, "Turn VoiceOver on or off", accessibility, combo(96, [.command]))
        add(162, "Show Accessibility controls", accessibility, combo(96, [.option, .command]))

        let screenshots = "Screenshots"
        add(28, "Save picture of screen as a file", screenshots, combo(20, [.shift, .command]))
        add(29, "Copy picture of screen to the clipboard", screenshots, combo(20, [.control, .shift, .command]))
        add(30, "Save picture of selected area as a file", screenshots, combo(21, [.shift, .command]))
        add(31, "Copy picture of selected area to the clipboard", screenshots, combo(21, [.control, .shift, .command]))
        add(184, "Screenshot and recording options", screenshots, combo(23, [.shift, .command]))

        let missionControl = "Mission Control"
        add(32, "Mission Control", missionControl, combo(126, [.control]))
        add(33, "Application windows", missionControl, combo(125, [.control]))
        add(36, "Show Desktop", missionControl, combo(103, []))
        add(79, "Move left a space", missionControl, combo(123, [.control]))
        add(81, "Move right a space", missionControl, combo(124, [.control]))
        add(163, "Show Notification Center", missionControl, nil)
        add(175, "Turn Do Not Disturb on or off", missionControl, nil)
        let digitKeys: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        for desktop in 1...16 {
            let key = desktop <= digitKeys.count ? combo(digitKeys[desktop - 1], [.control]) : nil
            add(117 + desktop, "Switch to Desktop \(desktop)", missionControl, key, enabled: false)
        }

        add(52, "Turn Dock hiding on or off", "Launchpad & Dock", combo(2, [.option, .command]))
        add(160, "Show Launchpad", "Launchpad & Dock", nil)
        add(60, "Select the previous input source", "Input Sources", combo(49, [.control]))
        add(61, "Select next source in Input menu", "Input Sources", combo(49, [.control, .option]))
        add(64, "Show Spotlight search", "Spotlight", combo(49, [.command]))
        add(65, "Show Finder search window", "Spotlight", combo(49, [.option, .command]))
        add(98, "Show Help menu", "App Shortcuts", combo(44, [.shift, .command]))
        add(190, "Quick Note", "Other", combo(12, [.function]))
        return table
    }()

    /// Slow-motion and modifier-only variants that would only duplicate rows.
    private static let hiddenIDs: Set<Int> = [34, 35, 37, 80, 82, 164]

    /// - Parameter symbolicHotKeys: the `AppleSymbolicHotKeys` dictionary of `com.apple.symbolichotkeys`.
    public static func entries(symbolicHotKeys: [String: Any]) -> [ShortcutEntry] {
        var ids = Set(defaults.keys)
        ids.formUnion(symbolicHotKeys.keys.compactMap(Int.init))
        ids.subtract(hiddenIDs)

        return ids.sorted().compactMap { id in
            let known = defaults[id]
            let stored = symbolicHotKeys[String(id)] as? [String: Any]
            var combo = known?.combo
            var isEnabled = known?.isEnabled ?? true
            if let stored {
                if let enabled = PlistValue.bool(stored["enabled"]) { isEnabled = enabled }
                switch storedCombo(stored) {
                case .cleared: combo = nil
                case .combo(let value): combo = value
                case .unreadable: break
                }
            }
            guard let combo else { return nil }
            return ShortcutEntry(
                combo: combo,
                action: known?.name ?? "macOS shortcut #\(id)",
                detail: known?.group ?? "Other",
                source: .macOS,
                scope: .global,
                isEnabled: isEnabled
            )
        }
    }

    private enum StoredCombo {
        case combo(KeyCombo)
        case cleared
        case unreadable
    }

    /// `parameters` is `[character, keyCode, cocoaModifiers]`; key code 65535 means no shortcut.
    private static func storedCombo(_ stored: [String: Any]) -> StoredCombo {
        guard let value = stored["value"] as? [String: Any],
              let parameters = value["parameters"] as? [Any], parameters.count >= 3,
              let rawKey = PlistValue.int(parameters[1]),
              let flags = PlistValue.modifierBits(parameters[2])
        else { return .unreadable }
        if rawKey == 65535 { return .cleared }
        guard let keyCode = PlistValue.keyCode(rawKey) else { return .unreadable }
        return .combo(KeyCombo(keyCode: keyCode, cocoaFlags: flags))
    }

    /// System shortcuts that can't be changed and aren't in the symbolic hotkey plist.
    public static let fixed: [ShortcutEntry] = [
        (combo(48, [.command]), "Switch apps"),
        (combo(48, [.shift, .command]), "Switch apps backward"),
        (combo(53, [.option, .command]), "Force Quit Applications"),
        (combo(12, [.control, .command]), "Lock Screen"),
        (combo(12, [.shift, .command]), "Log Out"),
        (combo(12, [.option, .shift, .command]), "Log Out immediately"),
        (combo(49, [.control, .command]), "Emoji & Symbols"),
    ].map { ShortcutEntry(combo: $0.0, action: $0.1, detail: "System", source: .macOS, scope: .global) }

    /// Shortcuts nearly every app uses; a global shortcut on one of these breaks it everywhere.
    public static let standard: [ShortcutEntry] = [
        (combo(12, [.command]), "Quit", "App"),
        (combo(4, [.command]), "Hide app", "App"),
        (combo(4, [.option, .command]), "Hide others", "App"),
        (combo(43, [.command]), "Settings", "App"),
        (combo(45, [.command]), "New", "File"),
        (combo(31, [.command]), "Open", "File"),
        (combo(1, [.command]), "Save", "File"),
        (combo(1, [.shift, .command]), "Save As or Duplicate", "File"),
        (combo(35, [.command]), "Print", "File"),
        (combo(13, [.command]), "Close window", "File"),
        (combo(6, [.command]), "Undo", "Edit"),
        (combo(6, [.shift, .command]), "Redo", "Edit"),
        (combo(7, [.command]), "Cut", "Edit"),
        (combo(8, [.command]), "Copy", "Edit"),
        (combo(9, [.command]), "Paste", "Edit"),
        (combo(0, [.command]), "Select All", "Edit"),
        (combo(3, [.command]), "Find", "Edit"),
        (combo(5, [.command]), "Find next", "Edit"),
        (combo(5, [.shift, .command]), "Find previous", "Edit"),
        (combo(17, [.command]), "New tab", "Window"),
        (combo(46, [.command]), "Minimize", "Window"),
        (combo(3, [.control, .command]), "Enter full screen", "View"),
        (combo(24, [.command]), "Zoom in", "View"),
        (combo(27, [.command]), "Zoom out", "View"),
        (combo(44, [.shift, .command]), "Help", "Help"),
    ].map { ShortcutEntry(combo: $0.0, action: $0.1, detail: $0.2, source: .standard, scope: .inApp) }
}
