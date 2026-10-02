import AppKit
import Combine
import MacToolsCore
import SwiftUI

@MainActor
final class StickyWindowCoordinator: NSObject {
    private let repository: StickyNoteRepository
    private let workspaceSettings: WorkspaceSettings
    private let desktopPresentation: DesktopPresentation?
    private var controllers: [UUID: StickyNoteWindowController] = [:]
    private var isActive = false

    init(repository: StickyNoteRepository, workspaceSettings: WorkspaceSettings = WorkspaceSettings(),
         desktopPresentation: DesktopPresentation? = nil) {
        self.repository = repository
        self.workspaceSettings = workspaceSettings
        self.desktopPresentation = desktopPresentation
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(reconcileDisplays), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(reconcileDisplays), name: NSWorkspace.didWakeNotification, object: nil)
    }

    func restoreActiveNotes() {
        isActive = true
        for note in repository.activeNotes where controllers[note.id] == nil {
            show(note: note, focus: false)
        }
    }

    func createNoteNearPointer() {
        let pointer = NSEvent.mouseLocation
        let screen = Self.screen(containing: pointer) ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }

        let frame = NoteGeometry.frame(near: pointer, in: screen.visibleFrame)
        let note = repository.create(frame: frame, displayID: Self.displayID(for: screen))
        show(note: note, focus: true)
    }

    func focus(noteID: UUID) {
        reconcileDisplays()
        guard let note = repository.note(id: noteID), note.deletedAt == nil else { return }
        if let controller = controllers[noteID] {
            controller.focus()
        } else {
            show(note: note, focus: true)
        }
    }

    func moveToRecentlyDeleted(noteID: UUID) {
        controllers[noteID]?.flushTextChange()
        controllers[noteID]?.hide()
        controllers[noteID] = nil
        repository.moveToRecentlyDeleted(id: noteID)
    }

    func restore(noteID: UUID) {
        repository.restore(id: noteID)
        guard let note = repository.note(id: noteID) else { return }
        show(note: note, focus: true)
    }

    func permanentlyDelete(noteID: UUID) {
        controllers[noteID]?.hide()
        controllers[noteID] = nil
        repository.permanentlyDelete(id: noteID)
    }

    func flushPendingChanges() {
        controllers.values.forEach { $0.flushTextChange() }
    }

    /// Saves and closes every note window; used when the tool is switched off.
    func closeAll() {
        isActive = false
        for controller in controllers.values {
            controller.flushTextChange()
            controller.hide()
        }
        controllers.removeAll()
    }

    @objc private func reconcileDisplays() {
        guard isActive else { return }
        let displays = Self.displays
        for note in repository.activeNotes {
            guard let controller = controllers[note.id] else {
                show(note: note, focus: false)
                continue
            }
            guard let placement = NoteGeometry.placement(frame: controller.window?.frame ?? note.frame,
                                                        displayID: note.displayID, displays: displays) else { continue }
            controller.setRestoredFrame(placement.frame)
            repository.updateFrame(id: note.id, frame: placement.frame, displayID: placement.displayID)
        }
    }

    private static var displays: [NoteDisplay] {
        NSScreen.screens.compactMap { screen in
            guard let id = displayID(for: screen) else { return nil }
            return NoteDisplay(id: id, visibleFrame: screen.visibleFrame)
        }
    }

    private func show(note: StickyNoteRecord, focus: Bool) {
        guard let placement = NoteGeometry.placement(frame: note.frame, displayID: note.displayID, displays: Self.displays) else { return }
        let adjustedFrame = placement.frame

        if adjustedFrame != note.frame || placement.displayID != note.displayID {
            repository.updateFrame(
                id: note.id,
                frame: adjustedFrame,
                displayID: placement.displayID
            )
        }

        let adjustedNote = repository.note(id: note.id) ?? note
        let controller = StickyNoteWindowController(
            note: adjustedNote,
            frame: adjustedFrame,
            focusInitially: focus,
            workspaceSettings: workspaceSettings,
            desktopPresentation: desktopPresentation,
            onTextChanged: { [weak self] id, text in self?.repository.updateText(id: id, text: text) },
            onPaletteChanged: { [weak self] id, palette in self?.repository.updatePalette(id: id, palette: palette) },
            onFrameChanged: { [weak self] id, frame, displayID in
                self?.repository.updateFrame(id: id, frame: frame, displayID: displayID)
            },
            onDelete: { [weak self] id in self?.moveToRecentlyDeleted(noteID: id) }
        )
        controllers[note.id] = controller
        controller.show(focus: focus)
    }

    private static func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }

    fileprivate static func displayID(for screen: NSScreen?) -> UInt32? {
        guard let screen,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return number.uint32Value
    }
}

@MainActor
private final class StickyNoteWindow: NSWindow {
    var suppressedForOverview = false
    override var canBecomeKey: Bool { !suppressedForOverview }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class StickyNoteWindowController: NSWindowController, NSWindowDelegate {
    private let noteID: UUID
    private let onTextChanged: (UUID, String) -> Void
    private let onFrameChanged: (UUID, CGRect, UInt32?) -> Void
    private var pendingText: String?
    private var textSaveTask: Task<Void, Never>?
    private var isReadyForFrameUpdates = false
    private var workspaceObservation: AnyCancellable?
    private var presentationObservation: AnyCancellable?
    private var currentWorkspaceMode: NoteWorkspaceMode
    private var overviewState: DesktopOverviewState = .unavailable
    private var overlayHidesNotes = false
    private var probeIsReady = false
    private var hidesNotes: Bool { overviewState.hidesNotes || overlayHidesNotes }
    private var pinsNotes: Bool { overviewState.canPin || probeIsReady }

    init(
        note: StickyNoteRecord,
        frame: CGRect,
        focusInitially: Bool,
        workspaceSettings: WorkspaceSettings = WorkspaceSettings(),
        desktopPresentation: DesktopPresentation? = nil,
        onTextChanged: @escaping (UUID, String) -> Void,
        onPaletteChanged: @escaping (UUID, NotePalette) -> Void,
        onFrameChanged: @escaping (UUID, CGRect, UInt32?) -> Void,
        onDelete: @escaping (UUID) -> Void
    ) {
        noteID = note.id
        self.onTextChanged = onTextChanged
        self.onFrameChanged = onFrameChanged
        currentWorkspaceMode = workspaceSettings.mode

        let window = StickyNoteWindow(
            contentRect: frame,
            styleMask: [.borderless, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = false
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.minSize = NoteGeometry.minimumSize
        window.maxSize = NoteGeometry.maximumSize
        // Keep notes above Finder's desktop input surface so they can be edited.
        // Pair with transient to exclude them from Mission Control. Show Desktop
        // also hides them; lowering this level is not a usable workaround.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        window.collectionBehavior = workspaceSettings.mode.collectionBehavior
        window.animationBehavior = .utilityWindow

        super.init(window: window)

        let content = StickyNoteView(
            note: note,
            focusInitially: focusInitially,
            onTextChanged: { [weak self] text in self?.scheduleTextChange(text) },
            onPaletteChanged: { palette in onPaletteChanged(note.id, palette) },
            onDelete: { onDelete(note.id) }
        )
        let hosting = NSHostingController(rootView: content)
        // AppKit owns note geometry; SwiftUI's ideal size must not replace the
        // saved frame or shrink a new note to the window's minimum size.
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setFrame(frame, display: false)
        window.delegate = self
        isReadyForFrameUpdates = true
        workspaceObservation = workspaceSettings.$mode.sink { [weak self] mode in
            self?.currentWorkspaceMode = mode
            self?.applyDesktopPresentation()
        }
        presentationObservation = desktopPresentation.map { presentation in
            presentation.$state
                .combineLatest(presentation.$overlayHidesNotes, presentation.$probeIsReady)
                .sink { [weak self] state, overlayHidesNotes, probeIsReady in
                    self?.overviewState = state
                    self?.overlayHidesNotes = overlayHidesNotes
                    self?.probeIsReady = probeIsReady
                    self?.applyDesktopPresentation()
                }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(focus: Bool) {
        guard let window else { return }
        if focus && !hidesNotes {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFrontRegardless()
        }
    }

    func focus() {
        show(focus: true)
    }

    func hide() {
        window?.orderOut(nil)
        textSaveTask?.cancel()
    }

    func setRestoredFrame(_ frame: CGRect) {
        guard window?.frame != frame else { return }
        isReadyForFrameUpdates = false
        window?.setFrame(frame, display: true)
        isReadyForFrameUpdates = true
    }

    func flushTextChange() {
        textSaveTask?.cancel()
        guard let pendingText else { return }
        self.pendingText = nil
        onTextChanged(noteID, pendingText)
    }

    func windowDidMove(_ notification: Notification) {
        saveFrameIfReady()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        saveFrameIfReady()
    }

    private func saveFrameIfReady() {
        guard isReadyForFrameUpdates, !hidesNotes, let window else { return }
        onFrameChanged(noteID, window.frame, StickyWindowCoordinator.displayID(for: window.screen))
    }

    private func applyDesktopPresentation() {
        guard let window = window as? StickyNoteWindow else { return }
        window.collectionBehavior = currentWorkspaceMode.collectionBehavior(pinned: pinsNotes)
        window.suppressedForOverview = hidesNotes
        if hidesNotes, window.isKeyWindow {
            window.resignKey()
        }
        window.ignoresMouseEvents = hidesNotes
        // Do not order out/recreate windows: that risks losing individual-Space
        // placement. Restoring alpha must not activate the app or steal focus.
        window.alphaValue = hidesNotes ? 0 : 1
    }

    private func scheduleTextChange(_ text: String) {
        pendingText = text
        textSaveTask?.cancel()
        textSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.flushTextChange()
        }
    }
}
