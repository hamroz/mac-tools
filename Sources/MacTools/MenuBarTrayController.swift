import AppKit
import MacToolsCore
import ScreenCaptureKit
import SwiftUI

@MainActor
final class MenuBarIconStore: ObservableObject {
    @Published private(set) var images: [MenuBarItemKey: NSImage] = [:]
    @Published private(set) var hasAccess = CGPreflightScreenCaptureAccess()
    private var updating = false

    func requestAccess() {
        guard !CGPreflightScreenCaptureAccess() else { hasAccess = true; return }
        _ = CGRequestScreenCaptureAccess()
        hasAccess = CGPreflightScreenCaptureAccess()
    }

    func refresh(_ items: [MenuBarItemSnapshot]) async {
        hasAccess = CGPreflightScreenCaptureAccess()
        guard hasAccess else { images.removeAll(); return }
        guard !updating, !items.isEmpty else { return }
        updating = true
        defer { updating = false }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            for item in items {
                try Task.checkCancellation()
                guard let id = item.windowID, let window = content.windows.first(where: { $0.windowID == id }),
                      window.frame.width > 0, window.frame.width < 300, window.frame.height < 80 else { continue }
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let configuration = SCStreamConfiguration()
                configuration.width = max(1, Int(window.frame.width * 2))
                configuration.height = max(1, Int(window.frame.height * 2))
                configuration.showsCursor = false
                configuration.capturesAudio = false
                configuration.ignoreShadowsSingleWindow = true
                guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) else { continue }
                try Task.checkCancellation()
                images[item.key] = NSImage(cgImage: image, size: window.frame.size)
            }
            let keys = Set(items.map(\.key))
            images = images.filter { keys.contains($0.key) }
        } catch { /* Keep the last successful glyph when an app is disappearing. */ }
    }
}

@MainActor
final class MenuBarTrayController {
    let icons = MenuBarIconStore()
    private var panel: MenuBarTrayPanel?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var refreshTask: Task<Void, Never>?
    private var onClose: (() -> Void)?
    var isVisible: Bool { panel?.isVisible == true }

    func toggle(relativeTo button: NSStatusBarButton, controller: MenuBarOrganizerController,
                settings: @escaping () -> Void, onClose: @escaping () -> Void) {
        if isVisible { close(); return }
        guard let window = button.window else { return }
        let items = controller.hiddenItems
        let screen = window.screen ?? NSScreen.main
        let available = screen?.visibleFrame ?? window.frame
        let width = min(max(CGFloat(items.count) * 42 + 60, 180), available.width - 24)
        let height: CGFloat = controller.errorMessage == nil ? 58 : 92
        let x = min(max(window.frame.maxX - width, available.minX + 12), available.maxX - width - 12)
        let frame = CGRect(x: x, y: window.frame.minY - height - 6, width: width, height: height)
        let panel = MenuBarTrayPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let content = MenuBarTrayView(controller: controller, icons: icons, openItem: { [weak self, weak controller] key in
            self?.close()
            controller?.revealAndPress(key)
        }, openSettings: { [weak self] in self?.close(); settings() })
        let effect = NSVisualEffectView(frame: CGRect(origin: .zero, size: frame.size))
        effect.material = .popover
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 1
        effect.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
        let hosting = NSHostingView(rootView: content)
        hosting.frame = effect.bounds
        hosting.autoresizingMask = [.width, .height]
        effect.addSubview(hosting)
        panel.contentView = effect
        panel.onDismiss = { [weak self] in self?.close() }
        self.panel = panel
        self.onClose = onClose
        panel.orderFrontRegardless()
        panel.makeKey()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                if event.type == .keyDown, event.keyCode == 53 { self?.close(); return true }
                if event.type != .keyDown, event.window !== self?.panel,
                   event.window !== button.window { self?.close() }
                return false
            }
            return consumed ? nil : event
        }
        refreshTask = Task { [weak self] in await self?.icons.refresh(items) }
    }

    func close() {
        refreshTask?.cancel()
        refreshTask = nil
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        panel?.orderOut(nil)
        panel = nil
        onClose?()
        onClose = nil
    }
}

@MainActor
private final class MenuBarTrayPanel: NSPanel {
    var onDismiss: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onDismiss?() }
}

private struct MenuBarTrayView: View {
    @ObservedObject var controller: MenuBarOrganizerController
    @ObservedObject var icons: MenuBarIconStore
    let openItem: (MenuBarItemKey) -> Void
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        if controller.hiddenItems.isEmpty {
                            Text("No hidden items").font(.callout).foregroundStyle(.secondary).padding(.horizontal, 10)
                        }
                        ForEach(controller.hiddenItems) { item in
                            Button { openItem(item.key) } label: {
                                Group {
                                    if let glyph = icons.images[item.key] {
                                        Image(nsImage: glyph).resizable().scaledToFit()
                                    } else if let icon = item.icon {
                                        Image(nsImage: icon).resizable().scaledToFit().padding(4)
                                    } else { Image(systemName: "app.dashed") }
                                }
                                .frame(width: min(max(item.size.width, 28), 64), height: 36)
                                .padding(1)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .help(item.title)
                            .accessibilityLabel("Open \(item.title)")
                            .disabled(controller.isBusy || controller.isArranging)
                            .contextMenu {
                                Button("Keep in Menu Bar") { controller.setHidden(false, for: item.key) }
                                Button("Move Left") { controller.moveItem(item.key, earlier: true) }
                                Button("Move Right") { controller.moveItem(item.key, earlier: false) }
                            }
                        }
                    }
                }.scrollIndicators(.hidden)
                Divider().frame(height: 22).padding(.horizontal, 4)
                Button(action: openSettings) { Image(systemName: "gearshape").frame(width: 24, height: 30) }
                    .buttonStyle(.borderless).help("Organizer Settings").accessibilityLabel("Organizer Settings")
            }
            if let error = controller.errorMessage {
                Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
