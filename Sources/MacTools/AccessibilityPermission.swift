import AppKit
import ApplicationServices
import Combine

/// Shared Accessibility (TCC) state for every tool that needs it. Checking is
/// silent; the system prompt appears only from `request()`, an explicit action.
@MainActor
final class AccessibilityPermission: ObservableObject {
    static let shared = AccessibilityPermission()

    @Published private(set) var isTrusted = AXIsProcessTrusted()
    private var observer: NSObjectProtocol?

    private init() {
        // Posted whenever any app's Accessibility approval changes.
        observer = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { _ in
            // The new value is readable only a moment after the notification.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                AccessibilityPermission.shared.refresh()
            }
        }
    }

    @discardableResult
    func refresh() -> Bool {
        let trusted = AXIsProcessTrusted()
        if trusted != isTrusted { isTrusted = trusted }
        return trusted
    }

    /// Shows the system prompt that leads to Privacy & Security → Accessibility.
    func request() {
        guard !refresh() else { return }
        // The C SDK exposes this immutable option key as a mutable global.
        // Use its verified string value instead of weakening Swift 6 isolation.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
