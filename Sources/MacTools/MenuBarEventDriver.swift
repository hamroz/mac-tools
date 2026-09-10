import AppKit

struct MenuBarWindowInfo {
    let id: CGWindowID
    let pid: pid_t
    let frame: CGRect
    var title: String = ""
}

@MainActor
enum MenuBarWindowCatalog {
    static func items() -> [MenuBarWindowInfo] {
        guard let list = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { row in
            guard let level = row[kCGWindowLayer as String] as? Int,
                  level == Int(CGWindowLevelForKey(.statusWindow)),
                  let id = row[kCGWindowNumber as String] as? UInt32,
                  let pid = row[kCGWindowOwnerPID as String] as? Int32,
                  let bounds = row[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.height > 0, frame.height < 80, frame.width > 0 else { return nil }
            return MenuBarWindowInfo(id: id, pid: pid, frame: frame, title: row[kCGWindowName as String] as? String ?? "")
        }
    }

    static func match(pid: pid_t, frame: CGRect, in windows: [MenuBarWindowInfo]) -> MenuBarWindowInfo? {
        // AX describes the glyph; the window includes menu bar padding. Cross-
        // process hosting requires hit-test evidence, never a nearest neighbor guess.
        let candidates = windows.filter { $0.pid == pid && distance($0.frame, frame) <= 1.5 }
        return candidates.count == 1 ? candidates[0] : nil
    }

    private static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat { hypot(a.midX - b.midX, a.midY - b.midY) }
}

/// Window-targeted menu bar events. Public CoreGraphics functions plus the
/// undocumented window-number event field (0x33). Isolated here because macOS
/// does not offer a public API for rearranging other applications' status items.
/// See docs/menu-bar-organizer.md for evidence and compatibility boundaries.
@MainActor
enum MenuBarEventDriver {
    static func move(windowID: CGWindowID, pid: pid_t, from original: CGRect, to destination: CGPoint) async throws {
        guard AXIsProcessTrusted() else { throw MenuBarOperationError.permission }
        try await waitForInputRelease()
        guard let source = CGEventSource(stateID: .hidSystemState) else { throw MenuBarOperationError.unavailable }
        source.localEventsSuppressionInterval = 0
        let candidates = MenuBarWindowCatalog.items().filter { $0.id != windowID && abs($0.frame.midY - destination.y) < 20 }
        func edgeDistance(_ frame: CGRect) -> CGFloat { min(abs(frame.minX - destination.x), abs(frame.maxX - destination.x)) }
        let target = candidates.min { edgeDistance($0.frame) < edgeDistance($1.frame) }
        let outside = CGPoint(x: (NSScreen.screens.map { $0.frame.maxX }.max() ?? 2000) + 1000,
                              y: (NSScreen.screens.map { $0.frame.maxY }.max() ?? 2000) + 1000)
        let down = try event(.leftMouseDown, at: outside, windowID: windowID, pid: pid, source: source, command: true)
        let up = try event(.leftMouseUp, at: destination, windowID: target?.id ?? windowID, pid: pid, source: source)
        let cancel = try event(.leftMouseUp, at: CGPoint(x: original.midX, y: original.midY), windowID: windowID, pid: pid, source: source)
        let cursor = CGEvent(source: nil)?.location
        var released = false
        CGDisplayHideCursor(CGMainDisplayID())
        defer {
            if !released { cancel.post(tap: .cgSessionEventTap); cancel.postToPid(pid) }
            if let cursor { CGWarpMouseCursorPosition(cursor) }
            CGDisplayShowCursor(CGMainDisplayID())
        }
        try await MenuBarEventDelivery(event: down, pid: pid).send()
        try await Task.sleep(for: .milliseconds(70))
        try await MenuBarEventDelivery(event: up, pid: pid).send()
        released = true
    }

    static func click(windowID: CGWindowID, pid: pid_t, frame: CGRect, rightButton: Bool = false) async throws {
        guard AXIsProcessTrusted() else { throw MenuBarOperationError.permission }
        try await waitForInputRelease()
        guard MenuBarCoordinates.isVisible(frame) else { throw MenuBarOperationError.layout }
        guard let source = CGEventSource(stateID: .hidSystemState) else { throw MenuBarOperationError.unavailable }
        let point = CGPoint(x: frame.midX, y: frame.midY)
        let down = try event(rightButton ? .rightMouseDown : .leftMouseDown, at: point, windowID: windowID, pid: pid, source: source)
        let up = try event(rightButton ? .rightMouseUp : .leftMouseUp, at: point, windowID: windowID, pid: pid, source: source)
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        // WindowServer also consults the actual cursor when routing hosted items.
        // Match it to the event, then restore it without leaving a pressed button.
        let cursor = CGEvent(source: nil)?.location
        var released = false
        CGDisplayHideCursor(CGMainDisplayID())
        defer {
            if !released { up.post(tap: .cgSessionEventTap) }
            if let cursor { CGWarpMouseCursorPosition(cursor) }
            CGDisplayShowCursor(CGMainDisplayID())
        }
        CGWarpMouseCursorPosition(point)
        try await Task.sleep(for: .milliseconds(20))
        try await MenuBarEventDelivery(event: down, pid: pid, relayToProcess: false).send()
        try await Task.sleep(for: .milliseconds(40))
        try await MenuBarEventDelivery(event: up, pid: pid, relayToProcess: false).send()
        released = true
    }

    private static func event(_ type: CGEventType, at point: CGPoint, windowID: CGWindowID, pid: pid_t,
                              source: CGEventSource, command: Bool = false) throws -> CGEvent {
        let right = type == .rightMouseDown || type == .rightMouseUp
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: right ? .right : .left),
              let windowField = CGEventField(rawValue: 0x33) else { throw MenuBarOperationError.unavailable }
        event.flags = command ? .maskCommand : []
        event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(pid))
        event.setIntegerValueField(windowField, value: Int64(windowID))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(windowID))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(windowID))
        return event
    }

    private static func waitForInputRelease() async throws {
        for _ in 0..<40 {
            try Task.checkCancellation()
            if NSEvent.pressedMouseButtons == 0,
               NSEvent.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw MenuBarOperationError.busy
    }
}

/// A short-lived handshake between the item's process and WindowServer. Taps
/// forward only this operation's tagged events and are removed on every exit.
@MainActor
private final class MenuBarEventDelivery {
    private let event: CGEvent
    private let pid: pid_t
    private let relayToProcess: Bool
    private let token = Int64.random(in: 1...Int64.max)
    private var processTap: CFMachPort?
    private var sessionTap: CFMachPort?
    private var sources: [CFRunLoopSource] = []
    private var delivered = false

    init(event: CGEvent, pid: pid_t, relayToProcess: Bool = true) {
        self.event = event; self.pid = pid; self.relayToProcess = relayToProcess
    }

    func send() async throws {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let wake = CGEvent(source: nil) else { throw MenuBarOperationError.unavailable }
        event.setIntegerValueField(.eventSourceUserData, value: token)
        wake.setIntegerValueField(.eventSourceUserData, value: token)
        processTap = CGEvent.tapCreateForPid(pid: pid, place: .tailAppendEventTap, options: .defaultTap,
                                            eventsOfInterest: 1 << CGEventType.null.rawValue, callback: Self.processCallback, userInfo: context)
        sessionTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                      eventsOfInterest: 1 << event.type.rawValue, callback: Self.sessionCallback, userInfo: context)
        defer { cleanup() }
        guard let processTap, let sessionTap else { throw MenuBarOperationError.permission }
        for tap in [processTap, sessionTap] {
            guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { throw MenuBarOperationError.unavailable }
            sources.append(source)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        wake.postToPid(pid)
        for _ in 0..<40 {
            try Task.checkCancellation()
            if delivered { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw MenuBarOperationError.moveFailed
    }

    private func cleanup() {
        for source in sources { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        for tap in [processTap, sessionTap].compactMap({ $0 }) { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        sources.removeAll()
        processTap = nil
        sessionTap = nil
    }

    private static let processCallback: CGEventTapCallBack = { _, type, event, context in
        guard let context else { return Unmanaged.passUnretained(event) }
        let delivery = Unmanaged<MenuBarEventDelivery>.fromOpaque(context).takeUnretainedValue()
        let userData = event.getIntegerValueField(.eventSourceUserData)
        let consumed = MainActor.assumeIsolated {
            guard type == .null, userData == delivery.token else { return false }
            if let tap = delivery.processTap { CGEvent.tapEnable(tap: tap, enable: false) }
            delivery.event.post(tap: .cgSessionEventTap)
            return true
        }
        return consumed ? nil : Unmanaged.passUnretained(event)
    }

    private static let sessionCallback: CGEventTapCallBack = { _, type, event, context in
        guard let context else { return Unmanaged.passUnretained(event) }
        let delivery = Unmanaged<MenuBarEventDelivery>.fromOpaque(context).takeUnretainedValue()
        let userData = event.getIntegerValueField(.eventSourceUserData)
        MainActor.assumeIsolated {
            guard type == delivery.event.type, userData == delivery.token,
                  !delivery.delivered else { return }
            if let tap = delivery.sessionTap { CGEvent.tapEnable(tap: tap, enable: false) }
            // Moves need the process relay. A normal click must traverse the
            // session only once, otherwise toggle-style popovers close again.
            if delivery.relayToProcess { delivery.event.postToPid(delivery.pid) }
            delivery.delivered = true
        }
        return Unmanaged.passUnretained(event)
    }
}
