import Foundation

/// Finds shortcuts in any app's preferences by the shapes common shortcut libraries save them in.
public enum PreferenceShortcutScanner {
    private static let keyboardShortcutsPrefix = "KeyboardShortcuts_"
    private static let maxDepth = 3

    public static func entries(bundleID: String, appName: String, preferences: [String: Any], isRunning: Bool) -> [ShortcutEntry] {
        let source = ShortcutSource.app(bundleID: bundleID, name: appName)
        var found: [(name: String, combo: KeyCombo)] = []

        for (key, value) in preferences {
            if key.hasPrefix(keyboardShortcutsPrefix) {
                // sindresorhus/KeyboardShortcuts: a JSON string with Carbon values.
                if let string = value as? String, let combo = keyboardShortcutsCombo(string) {
                    found.append((String(key.dropFirst(keyboardShortcutsPrefix.count)), combo))
                }
            } else {
                walk(key: key, value: value, depth: 1, into: &found)
            }
        }

        var seen = Set<String>()
        return found
            .sorted { $0.name < $1.name }
            .compactMap { name, combo in
                let action = humanize(name)
                guard seen.insert("\(action)|\(combo)").inserted else { return nil }
                return ShortcutEntry(
                    combo: combo, action: action, source: source, scope: .global,
                    isProbablyInApp: isProbablyInApp(combo), isSourceRunning: isRunning
                )
            }
    }

    private static func walk(key: String, value: Any, depth: Int, into found: inout [(name: String, combo: KeyCombo)]) {
        guard depth <= maxDepth, let dictionary = value as? [String: Any] else { return }
        if let combo = dictionaryCombo(dictionary) {
            found.append((key, combo))
            return
        }
        for (childKey, child) in dictionary {
            walk(key: childKey, value: child, depth: depth + 1, into: &found)
        }
    }

    /// `{keyCode, modifierFlags}` or `{keyCode, modifiers}` (Cocoa flags), or `{carbonKeyCode, carbonModifiers}`.
    private static func dictionaryCombo(_ dictionary: [String: Any]) -> KeyCombo? {
        if dictionary["keyCode"] != nil {
            guard let keyCode = PlistValue.keyCode(dictionary["keyCode"]),
                  let flags = PlistValue.modifierBits(dictionary["modifierFlags"] ?? dictionary["modifiers"])
            else { return nil }
            return KeyCombo(keyCode: keyCode, modifiers: ShortcutModifiers(cocoa: flags))
        }
        if dictionary["carbonKeyCode"] != nil {
            return carbonCombo(dictionary)
        }
        return nil
    }

    private static func carbonCombo(_ dictionary: [String: Any]) -> KeyCombo? {
        guard let keyCode = PlistValue.keyCode(dictionary["carbonKeyCode"]),
              let modifiers = PlistValue.modifierBits(dictionary["carbonModifiers"])
        else { return nil }
        return KeyCombo(keyCode: keyCode, modifiers: ShortcutModifiers(carbon: modifiers))
    }

    private static func keyboardShortcutsCombo(_ json: String) -> KeyCombo? {
        guard let data = json.data(using: .utf8),
              let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return carbonCombo(dictionary)
    }

    /// Global hotkeys almost always use ⌃ or ⌥, Space, or an F-key; ⌘ or ⇧⌘ plus a key is a menu shortcut.
    public static func isProbablyInApp(_ combo: KeyCombo) -> Bool {
        let modifiers = combo.modifiers.subtracting(.function)
        guard modifiers.isSubset(of: [.shift, .command]) else { return false }
        return combo.keyCode != 49 && !KeyNames.isFunctionKey(combo.keyCode)
    }

    /// `NSUserKeyEquivalents` (System Settings → Keyboard → App Shortcuts): menu title → `@~^$` key string.
    public static func userKeyEquivalents(_ value: Any?, source: ShortcutSource) -> [ShortcutEntry] {
        guard let dictionary = value as? [String: Any] else { return [] }
        return dictionary.sorted { $0.key < $1.key }.compactMap { title, keys in
            guard let keys = keys as? String, let combo = KeyCombo(userKeyEquivalent: keys) else { return nil }
            // A menu path is written with ESC separators: "\u{1B}File\u{1B}Export".
            let path = title.split(separator: "\u{1B}").map(String.init)
            guard let action = path.last else { return nil }
            let menus = path.dropLast().joined(separator: " ▸ ")
            return ShortcutEntry(
                combo: combo, action: action, detail: menus.isEmpty ? "Your app shortcut" : menus,
                source: source, scope: .inApp
            )
        }
    }

    /// `toggleLauncher` → "Toggle launcher".
    public static func humanize(_ key: String) -> String {
        let sentence = words(in: key).map { $0.lowercased() }.joined(separator: " ")
        return sentence.prefix(1).uppercased() + sentence.dropFirst()
    }

    /// Splits identifiers on separators and case changes, keeping acronyms together.
    static func words(in key: String) -> [String] {
        var words: [String] = []
        var current = ""
        let characters = Array(key)
        for (index, character) in characters.enumerated() {
            if "_.- ".contains(character) {
                if !current.isEmpty { words.append(current) }
                current = ""
                continue
            }
            if character.isUppercase, !current.isEmpty {
                let previous = characters[index - 1]
                let next = index + 1 < characters.count ? characters[index + 1] : nil
                if previous.isLowercase || previous.isNumber || (previous.isUppercase && next?.isLowercase == true) {
                    words.append(current)
                    current = ""
                }
            }
            current.append(character)
        }
        if !current.isEmpty { words.append(current) }
        return words
    }
}
