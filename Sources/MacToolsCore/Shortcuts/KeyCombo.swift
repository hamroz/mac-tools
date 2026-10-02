import Foundation

/// Modifier keys of a shortcut, independent of the API that reported them.
public struct ShortcutModifiers: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let control = ShortcutModifiers(rawValue: 1 << 0)
    public static let option = ShortcutModifiers(rawValue: 1 << 1)
    public static let shift = ShortcutModifiers(rawValue: 1 << 2)
    public static let command = ShortcutModifiers(rawValue: 1 << 3)
    public static let function = ShortcutModifiers(rawValue: 1 << 4)

    /// Carbon `cmdKey`/`shiftKey`/`optionKey`/`controlKey` bits, as `RegisterEventHotKey` and KeyboardShortcuts store them.
    public init(carbon: Int) {
        var value: ShortcutModifiers = []
        if carbon & 256 != 0 { value.insert(.command) }
        if carbon & 512 != 0 { value.insert(.shift) }
        if carbon & 2048 != 0 { value.insert(.option) }
        if carbon & 4096 != 0 { value.insert(.control) }
        self = value
    }

    /// `NSEvent.ModifierFlags` bits, as symbolic hotkeys and MASShortcut store them.
    public init(cocoa: Int) {
        var value: ShortcutModifiers = []
        if cocoa & 0x20000 != 0 { value.insert(.shift) }
        if cocoa & 0x40000 != 0 { value.insert(.control) }
        if cocoa & 0x80000 != 0 { value.insert(.option) }
        if cocoa & 0x100000 != 0 { value.insert(.command) }
        if cocoa & 0x800000 != 0 { value.insert(.function) }
        self = value
    }

    /// `AXMenuItemCmdModifiers`: Command is implied unless bit 3 is set.
    public init(axMenu: Int) {
        var value: ShortcutModifiers = axMenu & 8 == 0 ? [.command] : []
        if axMenu & 1 != 0 { value.insert(.shift) }
        if axMenu & 2 != 0 { value.insert(.option) }
        if axMenu & 4 != 0 { value.insert(.control) }
        self = value
    }

    /// ⌃⌥⇧⌘, the order macOS menus use, with `fn` first.
    public var symbols: String {
        var text = contains(.function) ? "fn" : ""
        if contains(.control) { text += "⌃" }
        if contains(.option) { text += "⌥" }
        if contains(.shift) { text += "⇧" }
        if contains(.command) { text += "⌘" }
        return text
    }

    var words: String {
        var words: [String] = []
        if contains(.function) { words.append("fn function globe") }
        if contains(.control) { words.append("ctrl control") }
        if contains(.option) { words.append("opt option alt") }
        if contains(.shift) { words.append("shift") }
        if contains(.command) { words.append("cmd command") }
        return words.joined(separator: " ")
    }
}

/// A key plus modifiers. Key codes are hardware codes, named for the US layout.
public struct KeyCombo: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let keyCode: UInt16
    public let modifiers: ShortcutModifiers

    public init(keyCode: UInt16, modifiers: ShortcutModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Parses an `NSUserKeyEquivalents` value such as `@$k` (⇧⌘K).
    public init?(userKeyEquivalent: String) {
        // Only modifier symbols means the key is missing, not that the key is "@".
        guard userKeyEquivalent.contains(where: { !"@~^$#".contains($0) }) else { return nil }
        var modifiers: ShortcutModifiers = []
        var rest = Substring(userKeyEquivalent)
        while let first = rest.first, rest.count > 1 {
            switch first {
            case "@": modifiers.insert(.command)
            case "~": modifiers.insert(.option)
            case "^": modifiers.insert(.control)
            case "$": modifiers.insert(.shift)
            case "#": break // keypad marker; the key code below already says which key
            default: break
            }
            guard "@~^$#".contains(first) else { break }
            rest = rest.dropFirst()
        }
        guard rest.count == 1, let stroke = KeyNames.keyStroke(forCharacter: String(rest)) else { return nil }
        if stroke.shift { modifiers.insert(.shift) }
        self.init(keyCode: stroke.keyCode, modifiers: modifiers)
    }

    public var keyName: String { KeyNames.name(for: keyCode) }

    public var displayString: String { modifiers.symbols + keyName }

    /// Text that search matches: symbols plus spelled-out names ("ctrl opt n").
    public var searchText: String {
        "\(displayString) \(modifiers.words) \(KeyNames.spokenName(for: keyCode))"
    }

    public var description: String { displayString }

    public static func < (lhs: KeyCombo, rhs: KeyCombo) -> Bool {
        if lhs.keyName != rhs.keyName { return lhs.keyName < rhs.keyName }
        return lhs.modifiers.rawValue < rhs.modifiers.rawValue
    }
}

public enum KeyNames {
    private static let characters: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
        "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
        "n": 45, "m": 46, ".": 47, "`": 50,
    ]

    /// Characters typed with Shift on a US keyboard, mapped to the unshifted key.
    private static let shifted: [String: String] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8",
        "(": "9", ")": "0", "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\",
        ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
    ]

    /// Keys whose name isn't the character they type.
    private static let special: [UInt16: (name: String, spoken: String)] = [
        36: ("↩", "return enter"), 48: ("⇥", "tab"), 49: ("Space", "space"), 51: ("⌫", "delete backspace"),
        53: ("⎋", "esc escape"), 117: ("⌦", "forward delete"), 115: ("↖", "home"), 119: ("↘", "end"),
        116: ("⇞", "page up"), 121: ("⇟", "page down"), 114: ("Help", "help"),
        123: ("←", "left arrow"), 124: ("→", "right arrow"), 125: ("↓", "down arrow"), 126: ("↑", "up arrow"),
        76: ("⌤", "keypad enter"), 71: ("⌧", "keypad clear"),
        65: ("Keypad .", "keypad"), 67: ("Keypad *", "keypad"), 69: ("Keypad +", "keypad"),
        75: ("Keypad /", "keypad"), 78: ("Keypad -", "keypad"), 81: ("Keypad =", "keypad"),
        82: ("Keypad 0", "keypad"), 83: ("Keypad 1", "keypad"), 84: ("Keypad 2", "keypad"),
        85: ("Keypad 3", "keypad"), 86: ("Keypad 4", "keypad"), 87: ("Keypad 5", "keypad"),
        88: ("Keypad 6", "keypad"), 89: ("Keypad 7", "keypad"), 91: ("Keypad 8", "keypad"),
        92: ("Keypad 9", "keypad"),
    ]

    /// F1–F20 in order.
    static let functionKeys: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]

    private static let namesByCode: [UInt16: String] = {
        var names: [UInt16: String] = [:]
        for (character, code) in characters { names[code] = character.uppercased() }
        for (code, entry) in special { names[code] = entry.name }
        for (index, code) in functionKeys.enumerated() { names[code] = "F\(index + 1)" }
        return names
    }()

    public static func name(for keyCode: UInt16) -> String {
        namesByCode[keyCode] ?? "Key \(keyCode)"
    }

    static func spokenName(for keyCode: UInt16) -> String {
        if let special = special[keyCode] { return special.spoken }
        return name(for: keyCode).lowercased()
    }

    public static func isFunctionKey(_ keyCode: UInt16) -> Bool {
        functionKeys.contains(keyCode)
    }

    /// The key that types `character` without Shift, or nil when it needs Shift or isn't on a US keyboard.
    public static func keyCode(forCharacter character: String) -> UInt16? {
        characters[character.lowercased()]
    }

    /// The key that types `character`, and whether Shift is part of typing it.
    public static func keyStroke(forCharacter character: String) -> (keyCode: UInt16, shift: Bool)? {
        if let code = characters[character.lowercased()] { return (code, false) }
        if let base = shifted[character], let code = characters[base] { return (code, true) }
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else { return nil }
        switch scalar.value {
        case 0x0D, 0x03: return (36, false)
        case 0x09: return (48, false)
        case 0x20: return (49, false)
        case 0x08, 0x7F: return (51, false)
        case 0x1B: return (53, false)
        case 0xF700: return (126, false)
        case 0xF701: return (125, false)
        case 0xF702: return (123, false)
        case 0xF703: return (124, false)
        case 0xF704...0xF717: return (functionKeys[Int(scalar.value - 0xF704)], false)
        case 0xF728: return (117, false)
        case 0xF729: return (115, false)
        case 0xF72B: return (119, false)
        case 0xF72C: return (116, false)
        case 0xF72D: return (121, false)
        default: return nil
        }
    }

    /// `AXMenuItemCmdGlyph` values (the Carbon `kMenu…Glyph` constants) for keys that have no character.
    public static func keyCode(forMenuGlyph glyph: Int) -> UInt16? {
        switch glyph {
        case 0x64: 123
        case 0x65: 124
        case 0x68: 126
        case 0x6A: 125
        case 0x6F...0x7A: functionKeys[glyph - 0x6F] // F1–F12
        case 0x87...0x89: functionKeys[12 + glyph - 0x87] // F13–F15
        case 0x04, 0x0B: 36
        case 0x02: 48
        case 0x09: 49
        case 0x17: 51
        case 0x0A: 117
        case 0x1B: 53
        case 0x62: 116
        case 0x6B: 121
        case 0x66: 115
        case 0x67: 119
        default: nil
        }
    }

    /// Keys offered by the checker's key picker: letters, digits, punctuation, then special and F-keys.
    public static let pickerKeys: [UInt16] = {
        let letters = "abcdefghijklmnopqrstuvwxyz".map { characters[String($0)]! }
        let digits = "1234567890".map { characters[String($0)]! }
        let punctuation = "-=[]\\;',./`".map { characters[String($0)]! }
        return letters + digits + punctuation + [49, 36, 48, 51, 117, 53, 123, 124, 126, 125, 115, 119, 116, 121] + functionKeys
    }()
}
