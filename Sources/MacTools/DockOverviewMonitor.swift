import AppKit
import ApplicationServices
import Combine

/// Uses public AX observer APIs with UNDOCUMENTED Dock notification names.
/// See docs/show-desktop-prototype.md for provenance and the compatibility risk.
/// It neither changes system settings nor records other applications' content.
@MainActor
final class DockOverviewMonitor: ObservableObject {
    let presentation: DesktopPresentation
    @Published private(set) var status = "Accessibility permission is required."
    @Published private(set) var lastEvent = "No Dock event received"
    private var observer: AXObserver?
    private var dockElement: AXUIElement?
    private var dockPID: pid_t?
    private var maintenance: Task<Void, Never>?
    private var failedPID: pid_t?
    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Mac Tools"
    }
    private static let notifications = [
        "AXExposeShowDesktop", "AXExposeShowAllWindows",
        "AXExposeShowFrontWindows", "AXExposeExit"
    ]

    init(presentation: DesktopPresentation) { self.presentation = presentation }

    func start() {
        guard maintenance == nil else { return }
        refresh()
        maintenance = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
                self?.refresh()
            }
        }
    }

    func stop() {
        maintenance?.cancel()
        maintenance = nil
        disconnect()
        presentation.update(.unavailable)
    }

    // Called only from an explicit user action in Settings or the prototype UI.
    func requestPermission() {
        guard !AXIsProcessTrusted() else { retry(); return }
        // The C SDK exposes this immutable option key as a mutable global.
        // Use its verified string value instead of weakening Swift 6 isolation.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        retry()
    }

    func retry() {
        failedPID = nil
        refresh()
    }

    private func refresh() {
        guard AXIsProcessTrusted() else {
            disconnect()
            failedPID = nil
            presentation.update(.unavailable)
            status = "Accessibility is optional: the window probe already pins notes and hides them in Mission Control. Allow \(appName) in System Settings → Privacy & Security → Accessibility to add a fallback observer."
            return
        }
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
            .first?.processIdentifier else {
            disconnect()
            presentation.update(.unavailable)
            status = "Dock is unavailable. Using the original window behavior."
            return
        }
        if dockPID == pid, observer != nil { return }
        guard failedPID != pid else { return }
        disconnect()
        presentation.update(.unavailable)
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.5)
        var newObserver: AXObserver?
        let error = AXObserverCreate(pid, Self.callback, &newObserver)
        guard error == .success, let newObserver else {
            failedPID = pid
            status = "Cannot observe Dock (\(error.rawValue)). Original behavior preserved."
            return
        }
        var registered: [String] = []
        for notification in Self.notifications {
            let result = AXObserverAddNotification(newObserver, element, notification as CFString,
                                                   Unmanaged.passUnretained(self).toOpaque())
            guard result == .success else {
                for name in registered { AXObserverRemoveNotification(newObserver, element, name as CFString) }
                failedPID = pid
                status = "Dock rejected \(notification) (\(result.rawValue)). Original behavior preserved."
                return
            }
            registered.append(notification)
        }
        observer = newObserver
        dockElement = element
        dockPID = pid
        presentation.update(.unknown)
        status = "Connected (fallback observer). One Show Desktop cycle synchronizes it; the window probe already handles pinning."
        // The C callback executes on this run loop; it can safely enter MainActor.
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(newObserver), .commonModes)
    }

    private func disconnect() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            if let dockElement {
                for name in Self.notifications { AXObserverRemoveNotification(observer, dockElement, name as CFString) }
            }
        }
        observer = nil
        dockElement = nil
        dockPID = nil
    }

    private static let callback: AXObserverCallback = { observer, _, name, context in
        guard let context else { return }
        let monitor = Unmanaged<DockOverviewMonitor>.fromOpaque(context).takeUnretainedValue()
        let observerIdentity = UInt(bitPattern: Unmanaged.passUnretained(observer).toOpaque())
        let notification = name as String
        // The owning app retains the monitor and calls stop before releasing it.
        // Removing the main-run-loop source prevents callbacks after stop.
        MainActor.assumeIsolated {
            guard let current = monitor.observer,
                  UInt(bitPattern: Unmanaged.passUnretained(current).toOpaque()) == observerIdentity,
                  let state = DesktopOverviewState(notification: notification) else { return }
            monitor.lastEvent = "\(notification) · \(Date().formatted(date: .omitted, time: .standard))"
            monitor.status = "Connected — detected \(state.rawValue)"
            monitor.presentation.update(state)
        }
    }
}
