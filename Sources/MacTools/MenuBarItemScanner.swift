import AppKit
import MacToolsCore

struct MenuBarItemSnapshot: Identifiable {
    let key: MenuBarItemKey
    let title: String
    let appName: String?
    let bundleIdentifier: String?
    let icon: NSImage?
    var position: CGPoint
    var size: CGSize
    var processIdentifier: pid_t = 0
    var legacyKey: MenuBarItemKey?
    var canMove = true
    var windowID: CGWindowID?
    var hostProcessIdentifier: pid_t = 0

    var id: String { key.rawValue }
    var frame: CGRect { CGRect(origin: position, size: size) }
    var instanceID: String { "\(processIdentifier):\(windowID ?? 0)" }

    func hasSamePresentation(as other: Self) -> Bool {
        key == other.key && title == other.title && appName == other.appName &&
        bundleIdentifier == other.bundleIdentifier && frame == other.frame &&
        instanceID == other.instanceID && canMove == other.canMove
    }
}

enum MenuBarOperationError: LocalizedError {
    case unavailable, permission, immovable, busy, layout, moveFailed

    var errorDescription: String? {
        switch self {
        case .unavailable: "The item is no longer available. Refresh and try again."
        case .permission: "Allow Mac Tools in System Settings → Privacy & Security → Accessibility."
        case .immovable: "macOS keeps this system item in a fixed position."
        case .busy: "Release the mouse and modifier keys, then try again."
        case .layout: "Reveal the menu bar, then try again. Keep the divider to the left of the Mac Tools chevron."
        case .moveFailed: "macOS did not move this item. Use Arrange in Menu Bar and Command-drag it across the divider, then choose Done."
        }
    }
}

@MainActor
protocol MenuBarItemScanning: AnyObject {
    var isTrusted: Bool { get }
    var isInteracting: Bool { get }
    var unavailableItems: [MenuBarItemSnapshot] { get }
    func requestAccess()
    func openPrivacySettings()
    func scan() -> [MenuBarItemSnapshot]
    func move(_ key: MenuBarItemKey, to position: CGPoint) async throws
    func press(_ key: MenuBarItemKey) async throws
    func resolveRestoredItem(_ key: MenuBarItemKey, excluding previousWindows: Set<CGWindowID>, at position: CGPoint) async throws
}

extension MenuBarItemScanning {
    var unavailableItems: [MenuBarItemSnapshot] { [] }
    func resolveRestoredItem(_ key: MenuBarItemKey, excluding previousWindows: Set<CGWindowID>, at position: CGPoint) async throws { }
}

@MainActor
final class AXMenuBarItemScanner: MenuBarItemScanning {
    private(set) var lastRecoveryDiagnostics = "None"
    private var elements: [MenuBarItemKey: AXUIElement] = [:]
    private var cached: [MenuBarItemKey: MenuBarItemSnapshot] = [:]
    var unavailableItems: [MenuBarItemSnapshot] { cached.values.filter { $0.windowID == nil } }

    var isTrusted: Bool { AXIsProcessTrusted() }
    var isInteracting: Bool {
        NSEvent.pressedMouseButtons != 0 || !NSEvent.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
    }

    func requestAccess() {
        guard !isTrusted else { return }
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func scan() -> [MenuBarItemSnapshot] {
        guard isTrusted else { elements.removeAll(); cached.removeAll(); return [] }
        let applications = NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && $0.processIdentifier > 0 && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
        let running = Set(applications.map(\.processIdentifier))
        // The extras bar can temporarily omit an overflow item. Keep its last identity
        // while its process lives; never reassign it to another process after a restart.
        cached = cached.filter { running.contains($0.value.processIdentifier) }
        elements = elements.filter { cached[$0.key] != nil }
        let windows = MenuBarWindowCatalog.items()
        let windowsByID = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.05)
        var hitWindows: [(AXUIElement, pid_t, MenuBarWindowInfo)] = []
        let knownWindows = Set(cached.values.compactMap(\.windowID))
        for window in windows where !knownWindows.contains(window.id) && window.frame.width < 300 &&
            !window.title.hasPrefix("MacTools.") && MenuBarCoordinates.isVisible(window.frame) {
            var hit: AXUIElement?
            if AXUIElementCopyElementAtPosition(system, Float(window.frame.midX), Float(window.frame.midY), &hit) == .success,
               let hit {
                var pid: pid_t = 0
                // Hit testing can return a glyph's AXImage/AXButton descendant.
                // Its PID still identifies the source app; requiring the parent
                // menu-item role incorrectly loses ChatGPT and CopyClip.
                if AXUIElementGetPid(hit, &pid) == .success { hitWindows.append((hit, pid, window)) }
            }
        }
        cached = cached.compactMapValues { item in
            guard let id = item.windowID else { return item }
            guard let window = windowsByID[id], window.pid == item.hostProcessIdentifier else { return nil }
            var current = item
            current.position = window.frame.origin
            current.size = window.frame.size
            return current
        }
        for application in applications {
            let app = AXUIElementCreateApplication(application.processIdentifier)
            AXUIElementSetMessagingTimeout(app, 0.05)
            guard let barValue = value(app, kAXExtrasMenuBarAttribute),
                  CFGetTypeID(barValue) == AXUIElementGetTypeID() else { continue }
            let bar = unsafeDowncast(barValue, to: AXUIElement.self)
            let children = (value(bar, kAXChildrenAttribute) as? [AXUIElement] ?? []).filter {
                value($0, kAXRoleAttribute) as? String == kAXMenuBarItemRole &&
                frame(of: $0).map { $0.width > 0 && $0.height > 0 } == true
            }
            var counts: [String: Int] = [:]
            for child in children {
                guard value(child, kAXRoleAttribute) as? String == kAXMenuBarItemRole,
                      let frame = frame(of: child), frame.width > 0, frame.height > 0 else { continue }
                let identifier = value(child, kAXIdentifierAttribute) as? String ?? ""
                let description = value(child, kAXDescriptionAttribute) as? String ?? ""
                let title = value(child, kAXTitleAttribute) as? String ?? ""
                let name = [description, title, application.localizedName ?? ""].first { !$0.isEmpty } ?? "Menu Bar Item"
                let owner = application.bundleIdentifier ?? application.executableURL?.path ?? "pid:\(application.processIdentifier)"
                // Dynamic labels (CPU, date, battery percentage) must not change identity.
                let base = MenuBarItemKey(identifier: identifier, bundleIdentifier: owner, title: "status-item").rawValue
                let ordinal = counts[base, default: 0]
                counts[base] = ordinal + 1
                let key = MenuBarItemKey(rawValue: ordinal == 0 ? base : "\(base)#\(ordinal + 1)")
                let legacy = MenuBarItemKey(rawValue: identifier.isEmpty ? "app:\(owner)|\(name)" : "id:\(identifier)")
                let fixed = ["clock", "controlcenter", "siri", "screenrecording", "audiovideo"].contains {
                    identifier.lowercased().contains($0)
                } && owner.hasPrefix("com.apple.")
                let previousWindow = cached[key]?.windowID.flatMap { windowsByID[$0] }
                let hits = hitWindows.filter { $0.1 == application.processIdentifier }
                let hitWindow = hits.first { isDescendant($0.0, of: child) }?.2 ?? (children.count == 1 && hits.count == 1 ? hits.first?.2 : nil)
                let window = previousWindow.flatMap { $0.pid == cached[key]?.hostProcessIdentifier ? $0 : nil }
                    ?? hitWindow
                    ?? MenuBarWindowCatalog.match(pid: application.processIdentifier, frame: frame, in: windows)
                cached[key] = MenuBarItemSnapshot(
                    key: key, title: name, appName: application.localizedName,
                    bundleIdentifier: application.bundleIdentifier, icon: application.icon,
                    position: window?.frame.origin ?? frame.origin, size: window?.frame.size ?? frame.size, processIdentifier: application.processIdentifier,
                    legacyKey: legacy, canMove: !fixed, windowID: window?.id, hostProcessIdentifier: window?.pid ?? application.processIdentifier
                )
                elements[key] = child
            }
        }
        // A source app may keep a proxy even when macOS has not created an icon
        // (e.g. Allow in Menu Bar is off). Remember its preference, not a dead button.
        return cached.values.filter { $0.windowID != nil }.sorted {
            if $0.position.x == $1.position.x { return $0.id < $1.id }
            return $0.position.x < $1.position.x
        }
    }

    func move(_ key: MenuBarItemKey, to position: CGPoint) async throws {
        guard isTrusted else { throw MenuBarOperationError.permission }
        guard let item = scan().first(where: { $0.key == key }), let windowID = item.windowID else {
            throw MenuBarOperationError.unavailable
        }
        guard item.canMove else { throw MenuBarOperationError.immovable }
        try await MenuBarEventDriver.move(windowID: windowID, pid: item.hostProcessIdentifier, from: item.frame, to: position)
    }

    func press(_ key: MenuBarItemKey) async throws {
        guard isTrusted else { throw MenuBarOperationError.permission }
        guard let item = scan().first(where: { $0.key == key }), let windowID = item.windowID else {
            throw MenuBarOperationError.unavailable
        }
        try await MenuBarEventDriver.click(windowID: windowID, pid: item.hostProcessIdentifier, frame: item.frame)
    }

    /// macOS may recreate a restored icon straight into overflow. Briefly move
    /// only the unique newly created window into view to obtain actual AX owner
    /// evidence; never assign a hosted window based on proximity alone.
    func resolveRestoredItem(_ key: MenuBarItemKey, excluding previousWindows: Set<CGWindowID>, at position: CGPoint) async throws {
        guard isTrusted else { throw MenuBarOperationError.permission }
        _ = scan()
        guard let source = cached[key], source.windowID == nil else { return }
        let windows = MenuBarWindowCatalog.items()
        let known = Set(cached.values.compactMap(\.windowID))
        guard let candidate = MenuBarWindowCatalog.recoveryCandidate(in: windows, excluding: previousWindows.union(known)) else { return }
        lastRecoveryDiagnostics = "\(key.rawValue): candidate=\(candidate.id) original=\(NSStringFromRect(candidate.frame)) sourcePID=\(source.processIdentifier)"
        // Preserve its original neighbor so a failed identification can roll back.
        let neighbor = windows.filter { $0.id != candidate.id && $0.frame.minX >= candidate.frame.maxX - 1 && abs($0.frame.midY - candidate.frame.midY) < 2 }
            .min { $0.frame.minX < $1.frame.minX }
        try await MenuBarEventDriver.move(windowID: candidate.id, pid: candidate.pid, from: candidate.frame, to: position)
        var resolved: MenuBarItemSnapshot?
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(150))
            resolved = scan().first { $0.key == key && $0.windowID == candidate.id && $0.processIdentifier == source.processIdentifier }
            if resolved != nil { break }
        }
        if let moved = MenuBarWindowCatalog.items().first(where: { $0.id == candidate.id }) {
            var hit: AXUIElement?
            let result = AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(moved.frame.midX), Float(moved.frame.midY), &hit)
            var pid: pid_t = 0
            if let hit { AXUIElementGetPid(hit, &pid) }
            // The source extras bar can keep a stale proxy after OS removal.
            // A successful hit on the recreated window is direct owner evidence.
            // Bind only when this process exposes exactly one source item.
            if resolved == nil, result == .success, pid == source.processIdentifier,
               cached.values.filter({ $0.processIdentifier == pid }).count == 1 {
                var identified = source
                identified.windowID = moved.id
                identified.hostProcessIdentifier = moved.pid
                identified.position = moved.frame.origin
                identified.size = moved.frame.size
                cached[key] = identified
                resolved = identified
            }
            lastRecoveryDiagnostics += " moved=\(NSStringFromRect(moved.frame)) hit=\(result.rawValue) pid=\(pid) resolved=\(resolved != nil)\n" + cached.values.filter { $0.processIdentifier == source.processIdentifier }.map { "\($0.id) window=\($0.windowID ?? 0) frame=\(NSStringFromRect($0.frame))" }.joined(separator: "\n")
        }
        if let current = MenuBarWindowCatalog.items().first(where: { $0.id == candidate.id }) {
            let anchor = neighbor.flatMap { saved in MenuBarWindowCatalog.items().first { $0.id == saved.id } }
            let returnPoint = CGPoint(x: anchor.map { $0.frame.minX - 2 } ?? candidate.frame.midX, y: candidate.frame.midY)
            try await MenuBarEventDriver.move(windowID: current.id, pid: current.pid, from: current.frame, to: returnPoint)
            try await Task.sleep(for: .milliseconds(150))
            _ = scan()
        }
        guard resolved != nil else { throw MenuBarOperationError.unavailable }
    }

    private func isDescendant(_ element: AXUIElement, of ancestor: AXUIElement) -> Bool {
        var current = element
        for _ in 0..<8 {
            if CFEqual(current, ancestor) { return true }
            guard let parent = value(current, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { return false }
            current = unsafeDowncast(parent, to: AXUIElement.self)
        }
        return false
    }

    private func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        // Prefer an atomic rect; older apps can report stale proxy geometry in
        // either form. System-wide hit testing supplies the hosted identity.
        if let result = value(element, "AXFrame"), CFGetTypeID(result) == AXValueGetTypeID() {
            let value = unsafeDowncast(result, to: AXValue.self)
            var frame = CGRect.zero
            if AXValueGetType(value) == .cgRect, AXValueGetValue(value, .cgRect, &frame) { return frame }
        }
        guard let p = value(element, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
              let s = value(element, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        let position = unsafeDowncast(p, to: AXValue.self)
        let size = unsafeDowncast(s, to: AXValue.self)
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetType(position) == .cgPoint, AXValueGetType(size) == .cgSize,
              AXValueGetValue(position, .cgPoint, &point), AXValueGetValue(size, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }
}

@MainActor
enum MenuBarCoordinates {
    static func quartzFrame(_ frame: CGRect) -> CGRect {
        CGRect(x: frame.minX, y: (NSScreen.screens.first?.frame.maxY ?? 0) - frame.maxY, width: frame.width, height: frame.height)
    }

    static func isVisible(_ frame: CGRect) -> Bool {
        NSScreen.screens.contains { screen in
            let bounds = quartzFrame(screen.frame)
            guard bounds.contains(CGPoint(x: frame.midX, y: frame.midY)),
                  frame.minY >= bounds.minY - 2, frame.maxY <= bounds.minY + max(40, screen.safeAreaInsets.top) + 2 else { return false }
            if screen.safeAreaInsets.top > 0,
               let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
                return frame.maxX <= left.maxX || frame.minX >= right.minX
            }
            return true
        }
    }
}
