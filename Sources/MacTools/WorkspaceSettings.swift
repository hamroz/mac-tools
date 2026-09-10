import AppKit
import Combine
import Foundation

enum NoteWorkspaceMode: String, CaseIterable, Identifiable {
    case allWorkspaces
    case individualWorkspaces

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allWorkspaces: "All workspaces"
        case .individualWorkspaces: "One workspace per note"
        }
    }

    var explanation: String {
        switch self {
        case .allWorkspaces:
            "The same notes appear on every desktop workspace, on their chosen display. Editing a note updates it everywhere."
        case .individualWorkspaces:
            "Each note belongs to one desktop workspace. Create a note in the workspace where you want it. After restarting Mac Tools, saved notes return to the active workspace on their display."
        }
    }

    var collectionBehavior: NSWindow.CollectionBehavior {
        // transient hides notes in Mission Control, but also during Show Desktop.
        // stationary reintroduces the Mission Control overlay regression.
        // These flags are mutually exclusive; do not combine them.
        var behavior: NSWindow.CollectionBehavior = [.transient, .fullScreenNone, .ignoresCycle]
        if self == .allWorkspaces { behavior.insert(.canJoinAllSpaces) }
        return behavior
    }

    /// `stationary` keeps notes visible and editable during Show Desktop, so it
    /// is used as soon as either the window probe or the Dock observer is
    /// available to hide them during Mission Control.
    func collectionBehavior(pinned: Bool) -> NSWindow.CollectionBehavior {
        var behavior = collectionBehavior
        if pinned {
            behavior.remove(.transient)
            behavior.insert(.stationary)
        }
        return behavior
    }
}

@MainActor
final class WorkspaceSettings: ObservableObject {
    @Published private(set) var mode: NoteWorkspaceMode
    private let defaults: UserDefaults
    private static let key = "desktopStickies.workspaceMode"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = defaults.string(forKey: Self.key).flatMap(NoteWorkspaceMode.init(rawValue:)) ?? .allWorkspaces
    }

    func setMode(_ mode: NoteWorkspaceMode) {
        guard self.mode != mode else { return }
        defaults.set(mode.rawValue, forKey: Self.key)
        self.mode = mode
    }
}
