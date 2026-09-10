import AppKit
import MacToolsCore
import SwiftUI

extension HotKeyPreset {
    var appKitModifiers: NSEvent.ModifierFlags {
        modifiers.reduce(into: []) { flags, modifier in
            switch modifier {
            case .control: flags.insert(.control)
            case .option: flags.insert(.option)
            case .shift: flags.insert(.shift)
            case .command: flags.insert(.command)
            }
        }
    }

    var swiftUIModifiers: EventModifiers {
        modifiers.reduce(into: []) { flags, modifier in
            switch modifier {
            case .control: flags.insert(.control)
            case .option: flags.insert(.option)
            case .shift: flags.insert(.shift)
            case .command: flags.insert(.command)
            }
        }
    }
}
