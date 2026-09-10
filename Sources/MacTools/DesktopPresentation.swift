import Combine

enum DesktopOverviewState: String, Sendable {
    case unavailable, unknown, desktop, allWindows, applicationWindows, inactive

    init?(notification: String) {
        switch notification {
        case "AXExposeShowDesktop": self = .desktop
        case "AXExposeShowAllWindows": self = .allWindows
        case "AXExposeShowFrontWindows": self = .applicationWindows
        case "AXExposeExit": self = .inactive
        default: return nil
        }
    }

    var canPin: Bool { self != .unavailable && self != .unknown }
    var hidesNotes: Bool { self == .allWindows || self == .applicationWindows }
}

/// Kept separate from the Dock observer so transitions can be tested without
/// Accessibility permission or synthesizing system gestures.
@MainActor
final class DesktopPresentation: ObservableObject {
    @Published private(set) var state: DesktopOverviewState = .unavailable

    /// Set by the fast window-overlay probe while Mission Control or App Exposé
    /// is on screen. It fires on the first animation frame, before the Dock's
    /// AX notification arrives. Show Desktop leaves it false so notes stay
    /// visible there.
    @Published private(set) var overlayHidesNotes = false

    /// True once the window probe has inspected the Dock once. The probe does
    /// not need Accessibility, so notes pin even when that approval is stale or
    /// missing; the AX observer then only serves as a fallback hide path.
    @Published private(set) var probeIsReady = false

    var hidesNotes: Bool { state.hidesNotes || overlayHidesNotes }
    var pinsNotes: Bool { state.canPin || probeIsReady }

    func update(_ state: DesktopOverviewState) {
        guard self.state != state else { return }
        self.state = state
    }

    func updateOverlay(hidesNotes: Bool) {
        guard overlayHidesNotes != hidesNotes else { return }
        overlayHidesNotes = hidesNotes
    }

    func markProbeReady() {
        guard !probeIsReady else { return }
        probeIsReady = true
    }
}
