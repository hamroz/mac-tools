import AppKit
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

    func collectionBehavior(for mode: NoteWorkspaceMode) -> NSWindow.CollectionBehavior {
        var behavior = mode.collectionBehavior
        if canPin {
            behavior.remove(.transient)
            behavior.insert(.stationary)
        }
        return behavior
    }
}

/// Kept separate from the Dock observer so transitions can be tested without
/// Accessibility permission or synthesizing system gestures.
@MainActor
final class DesktopPresentation: ObservableObject {
    @Published private(set) var state: DesktopOverviewState = .unavailable

    func update(_ state: DesktopOverviewState) {
        guard self.state != state else { return }
        self.state = state
    }
}
