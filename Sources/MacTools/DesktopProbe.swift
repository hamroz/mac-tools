import AppKit
import MacToolsCore
import SwiftUI

/// Separate bundle identity, no repository, no shortcut/login registration.
@MainActor
final class DesktopProbe {
    private let presentation = DesktopPresentation()
    private let settings: WorkspaceSettings
    private let monitor: DockOverviewMonitor
    private var note: StickyNoteWindowController?
    private var controls: NSWindow?

    init() {
        // This separate bundle already has its own standard preferences domain.
        // Foundation rejects a suite named exactly like the current bundle ID.
        settings = WorkspaceSettings()
        monitor = DockOverviewMonitor(presentation: presentation)
    }

    func start() {
        let visible = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let frame = CGRect(x: visible.midX - 130, y: visible.midY - 100, width: 260, height: 200)
        let record = StickyNoteRecord(text: "TEST NOTE\n\nHover, type and drag here.\nNothing here is saved.", frame: frame)
        note = StickyNoteWindowController(note: record, frame: frame, focusInitially: false,
            workspaceSettings: settings, desktopPresentation: presentation,
            onTextChanged: { _, _ in }, onPaletteChanged: { _, _ in },
            onFrameChanged: { _, _, _ in }, onDelete: { [weak self] _ in self?.note?.hide() })
        note?.show(focus: false)
        let window = NSWindow(contentRect: CGRect(x: visible.minX + 40, y: visible.minY + 60, width: 510, height: 520),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Mac Tools Desktop Test — isolated prototype"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: DesktopProbeView(monitor: monitor, settings: settings))
        controls = window
        monitor.start()
        showControls()
    }

    func showControls() {
        NSApp.activate(ignoringOtherApps: true)
        controls?.makeKeyAndOrderFront(nil)
    }

    func stop() {
        monitor.stop()
        note?.hide()
        controls?.orderOut(nil)
    }
}

private struct DesktopProbeView: View {
    @ObservedObject var monitor: DockOverviewMonitor
    @ObservedObject var settings: WorkspaceSettings
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Show Desktop test").font(.title2.bold())
            Text("This app contains one disposable note. Your normal Mac Tools and saved notes are untouched.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Accessibility access lets this test observe Dock’s overview modes. The notification names are undocumented and may change with macOS updates.").font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Enable Accessibility…") { monitor.requestPermission() }
                Button("Recheck") { monitor.retry() }
            }
            Text(monitor.status).font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Text(monitor.lastEvent).font(.caption.monospaced()).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Workspaces", selection: Binding(get: { settings.mode }, set: { settings.setMode($0) })) {
                ForEach(NoteWorkspaceMode.allCases) { Text($0.title).tag($0) }
            }
            Text("After synchronization: Show Desktop must keep the TEST NOTE editable. Mission Control must hide it. Also check hover, dragging and both workspace modes.").font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Button("Quit Test") { NSApp.terminate(nil) }
        }
        .padding(22)
        .frame(width: 510, height: 520, alignment: .topLeading)
    }
}
