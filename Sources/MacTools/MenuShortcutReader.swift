import ApplicationServices
import Foundation
import MacToolsCore

/// Reads the shortcuts in an app's menu bar through Accessibility.
enum MenuShortcutReader {
    private static let maxDepth = 6
    private static let maxItems = 3000

    private static let attributes = [
        kAXRoleAttribute, kAXTitleAttribute, kAXEnabledAttribute, kAXChildrenAttribute,
        kAXMenuItemCmdCharAttribute, kAXMenuItemCmdVirtualKeyAttribute,
        kAXMenuItemCmdGlyphAttribute, kAXMenuItemCmdModifiersAttribute,
    ]

    /// Blocking; call off the main thread. Nil when the app has no readable menu bar.
    nonisolated static func capture(pid: pid_t, bundleID: String, name: String) -> CapturedApp? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        guard let menuBar: AXUIElement = copyAttribute(app, kAXMenuBarAttribute) else { return nil }

        var items: [MenuShortcut] = []
        var visited = 0
        let topLevel: [AXUIElement] = copyAttribute(menuBar, kAXChildrenAttribute) ?? []
        // The first menu is the Apple menu, the same in every app.
        for menu in topLevel.dropFirst() {
            let values = read(menu)
            guard let title = values.title, !title.isEmpty else { continue }
            walk(values.children, path: [title], depth: 1, items: &items, visited: &visited)
        }
        return CapturedApp(bundleID: bundleID, name: name, capturedAt: Date(), items: items)
    }

    private struct Values {
        var role: String?
        var title: String?
        var isEnabled = true
        var children: [AXUIElement] = []
        var character: String?
        var virtualKey: Int?
        var glyph: Int?
        var modifiers = 0
    }

    /// One round trip per element instead of one per attribute.
    private static func read(_ element: AXUIElement) -> Values {
        var raw: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, attributes as CFArray, [], &raw) == .success,
              let array = raw as? [Any], array.count == attributes.count
        else { return Values() }
        // Missing attributes come back as AXValue errors, which the casts below skip.
        var values = Values()
        values.role = array[0] as? String
        values.title = array[1] as? String
        values.isEnabled = (array[2] as? Bool) ?? true
        values.children = (array[3] as? [AXUIElement]) ?? []
        values.character = array[4] as? String
        values.virtualKey = (array[5] as? NSNumber)?.intValue
        values.glyph = (array[6] as? NSNumber)?.intValue
        values.modifiers = (array[7] as? NSNumber)?.intValue ?? 0
        return values
    }

    private static func walk(_ elements: [AXUIElement], path: [String], depth: Int, items: inout [MenuShortcut], visited: inout Int) {
        guard depth <= maxDepth else { return }
        for element in elements {
            guard visited < maxItems else { return }
            visited += 1
            let values = read(element)
            if values.role == kAXMenuRole as String {
                walk(values.children, path: path, depth: depth, items: &items, visited: &visited)
                continue
            }
            guard values.role == kAXMenuItemRole as String else { continue }
            let title = values.title ?? ""
            if !title.isEmpty, let combo = combo(values) {
                items.append(MenuShortcut(path: path, title: title, combo: combo, isEnabled: values.isEnabled))
            }
            if !values.children.isEmpty, !title.isEmpty {
                walk(values.children, path: path + [title], depth: depth + 1, items: &items, visited: &visited)
            }
        }
    }

    /// Virtual key first, then glyph (arrows, F-keys), then the character.
    private static func combo(_ values: Values) -> KeyCombo? {
        var modifiers = ShortcutModifiers(axMenu: values.modifiers)
        let keyCode: UInt16
        if let virtualKey = values.virtualKey, (0...0x7F).contains(virtualKey), values.character?.isEmpty != false {
            keyCode = UInt16(virtualKey)
        } else if let glyph = values.glyph, glyph != 0, let code = KeyNames.keyCode(forMenuGlyph: glyph) {
            keyCode = code
        } else if let character = values.character, !character.isEmpty,
                  let stroke = KeyNames.keyStroke(forCharacter: character) {
            keyCode = stroke.keyCode
            if stroke.shift { modifiers.insert(.shift) }
        } else {
            return nil
        }
        return KeyCombo(keyCode: keyCode, modifiers: modifiers)
    }

    private static func copyAttribute<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? T
    }
}
