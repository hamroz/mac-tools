import AppKit
import MacToolsCore
import SwiftUI

extension NotePalette {
    func backgroundColor(for scheme: ColorScheme) -> Color {
        let pair: (light: UInt32, dark: UInt32)
        switch self {
        case .sand: pair = (0xF3E8C8, 0x443D2D)
        case .sage: pair = (0xDCE9D5, 0x304135)
        case .sky: pair = (0xD9E8F1, 0x2D404B)
        case .rose: pair = (0xF0DBDC, 0x493336)
        case .graphite: pair = (0xE1E3E5, 0x303336)
        }
        return Color(rgb: scheme == .dark ? pair.dark : pair.light)
    }

    func foregroundColor(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(rgb: 0xF5F3ED) : Color(rgb: 0x202321)
    }

    func accentColor(for scheme: ColorScheme) -> Color {
        foregroundColor(for: scheme).opacity(scheme == .dark ? 0.72 : 0.62)
    }
}

extension Color {
    init(rgb: UInt32) {
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}
