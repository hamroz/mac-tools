import Foundation

public enum HotKeyModifier: String, Codable, CaseIterable, Sendable {
    case control
    case option
    case shift
    case command
}

public enum HotKeyPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case controlOptionN
    case controlOptionS
    case controlShiftN
    case commandOptionN

    public var id: String { rawValue }

    public var keyEquivalent: String {
        self == .controlOptionS ? "s" : "n"
    }

    public var keyCode: UInt32 {
        switch self {
        case .controlOptionN, .controlShiftN, .commandOptionN: 45
        case .controlOptionS: 1
        }
    }

    public var modifiers: Set<HotKeyModifier> {
        switch self {
        case .controlOptionN: [.control, .option]
        case .controlOptionS: [.control, .option]
        case .controlShiftN: [.control, .shift]
        case .commandOptionN: [.command, .option]
        }
    }

    public var displayName: String {
        switch self {
        case .controlOptionN: "⌥⌃N"
        case .controlOptionS: "⌥⌃S"
        case .controlShiftN: "⇧⌃N"
        case .commandOptionN: "⌥⌘N"
        }
    }
}
