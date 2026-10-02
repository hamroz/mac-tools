import Foundation

/// Rectangle saves only the shortcuts you changed; its defaults depend on `alternateDefaultShortcuts`.
public enum RectangleShortcuts {
    public static let bundleID = "com.knollsoft.Rectangle"

    private static func combo(_ keyCode: UInt16, _ modifiers: ShortcutModifiers) -> KeyCombo {
        KeyCombo(keyCode: keyCode, modifiers: modifiers)
    }

    /// Rectangle's recommended set (`alternateDefaultShortcuts` on).
    private static let recommended: [String: KeyCombo] = {
        let co: ShortcutModifiers = [.control, .option]
        return [
            "leftHalf": combo(123, co), "rightHalf": combo(124, co), "topHalf": combo(126, co), "bottomHalf": combo(125, co),
            "topLeft": combo(32, co), "topRight": combo(34, co), "bottomLeft": combo(38, co), "bottomRight": combo(40, co),
            "firstThird": combo(2, co), "centerThird": combo(3, co), "lastThird": combo(5, co),
            "firstTwoThirds": combo(14, co), "lastTwoThirds": combo(17, co),
            "maximize": combo(36, co), "maximizeHeight": combo(126, [.control, .option, .shift]),
            "smaller": combo(27, co), "larger": combo(24, co), "center": combo(8, co), "restore": combo(51, co),
            "nextDisplay": combo(124, [.control, .option, .command]), "previousDisplay": combo(123, [.control, .option, .command]),
        ]
    }()

    /// The Spectacle-style set (`alternateDefaultShortcuts` off).
    private static let spectacle: [String: KeyCombo] = {
        let oc: ShortcutModifiers = [.option, .command]
        return [
            "leftHalf": combo(123, oc), "rightHalf": combo(124, oc), "topHalf": combo(126, oc), "bottomHalf": combo(125, oc),
            "topLeft": combo(123, [.control, .command]), "topRight": combo(124, [.control, .command]),
            "bottomLeft": combo(123, [.control, .shift, .command]), "bottomRight": combo(124, [.control, .shift, .command]),
            "nextDisplay": combo(124, [.control, .option, .command]), "previousDisplay": combo(123, [.control, .option, .command]),
            "maximize": combo(3, oc), "smaller": combo(123, [.control, .option, .shift]),
            "larger": combo(124, [.control, .option, .shift]), "center": combo(8, oc), "restore": combo(51, [.control, .option]),
        ]
    }()

    private static let names: [String: String] = [
        "smaller": "Make Smaller", "larger": "Make Larger",
    ]

    public static func entries(preferences: [String: Any], isRunning: Bool) -> [ShortcutEntry] {
        let useRecommended = PlistValue.bool(preferences["alternateDefaultShortcuts"]) ?? true
        var combos = useRecommended ? recommended : spectacle
        for (key, value) in preferences {
            guard let stored = value as? [String: Any] else { continue }
            if stored.isEmpty, combos[key] != nil {
                combos[key] = nil // cleared in Rectangle's settings
            } else if let keyCode = PlistValue.keyCode(stored["keyCode"]),
                      let flags = PlistValue.modifierBits(stored["modifierFlags"]) {
                combos[key] = KeyCombo(keyCode: keyCode, modifiers: ShortcutModifiers(cocoa: flags))
            }
        }
        let source = ShortcutSource.app(bundleID: bundleID, name: "Rectangle")
        return combos.sorted { $0.key < $1.key }.map { key, combo in
            ShortcutEntry(
                combo: combo, action: names[key] ?? titleCase(key), detail: "Window management",
                source: source, scope: .global, isSourceRunning: isRunning
            )
        }
    }

    private static func titleCase(_ key: String) -> String {
        PreferenceShortcutScanner.words(in: key).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}
