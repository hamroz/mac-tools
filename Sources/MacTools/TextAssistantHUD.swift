import AppKit
import SwiftUI

/// A status bubble next to the pointer. It never becomes key or activates
/// Mac Tools, so the app being edited keeps its selection and gets the paste.
@MainActor
final class TextAssistantHUD: TextAssistantFeedback {
    /// Shown as a button on failures, which are usually fixed in Settings.
    var onOpenSettings: (() -> Void)?

    private(set) var panel: NSPanel?
    private var hosting: NSHostingController<HUDView>?
    private var hideTask: Task<Void, Never>?

    func show(_ status: TextAssistantStatus) {
        let panel = panel ?? makePanel()
        self.panel = panel
        let wasVisible = panel.isVisible
        hideTask?.cancel()

        // Size from the new content right away; an observed model would only
        // re-render on the next run loop pass and leave the panel at the old size.
        let view = HUDView(status: status, openSettings: { [weak self] in
            self?.hide()
            self?.onOpenSettings?()
        }, dismiss: { [weak self] in self?.hide() })
        hosting?.rootView = view
        let size = hosting?.sizeThatFits(in: CGSize(width: 1_000, height: 1_000)) ?? .zero
        let anchor = wasVisible ? CGPoint(x: panel.frame.minX, y: panel.frame.maxY) : nil
        panel.setContentSize(size)
        position(panel, keepingTopLeft: anchor)

        if case .failure = status {
            panel.ignoresMouseEvents = false
        } else {
            panel.ignoresMouseEvents = true
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        switch status {
        case .working: break
        case .success: scheduleHide(after: 1.4)
        case .failure: scheduleHide(after: 8)
        }
    }

    func hide() {
        hideTask?.cancel()
        panel?.orderOut(nil)
    }

    private func scheduleHide(after seconds: Double) {
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let panel = self?.panel else { return }
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                panel.animator().alphaValue = 0
            }
            guard !Task.isCancelled else { return }
            panel.orderOut(nil)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let hosting = FirstClickHostingController(rootView: HUDView(status: .working(""), openSettings: {}, dismiss: {}))
        hosting.sizingOptions = []
        panel.contentViewController = hosting
        self.hosting = hosting
        return panel
    }

    /// Below and to the right of the pointer, kept on its screen. While visible,
    /// the bubble stays put and only grows.
    private func position(_ panel: NSPanel, keepingTopLeft anchor: CGPoint?) {
        let size = panel.frame.size
        var origin: CGPoint
        let reference: CGPoint
        if let anchor {
            origin = CGPoint(x: anchor.x, y: anchor.y - size.height)
            reference = anchor
        } else {
            let pointer = NSEvent.mouseLocation
            origin = CGPoint(x: pointer.x + 16, y: pointer.y - 20 - size.height)
            reference = pointer
        }
        let screen = NSScreen.screens.first { $0.frame.contains(reference) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
            origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        }
        panel.setFrameOrigin(origin)
    }
}

/// Buttons in the bubble work on the first click, without focusing Mac Tools.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class FirstClickHostingController<Content: View>: NSHostingController<Content> {
    override func loadView() {
        view = FirstClickHostingView(rootView: rootView)
    }
}

struct HUDView: View {
    let status: TextAssistantStatus
    let openSettings: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .font(.system(size: 13, weight: isFailure ? .regular : .medium))
                    .foregroundStyle(.primary)
                    .frame(width: textWidth, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if isFailure {
                    HStack(spacing: 8) {
                        Button("Open Settings", action: openSettings)
                            .controlSize(.small)
                        Button("Dismiss", action: dismiss)
                            .controlSize(.small)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
        .fixedSize()
    }

    private var isFailure: Bool {
        if case .failure = status { return true }
        return false
    }

    @ViewBuilder private var icon: some View {
        switch status {
        case .working:
            ProgressView().controlSize(.small)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(.green)
        case .failure:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16))
                .foregroundStyle(.orange)
        }
    }

    /// One line when it fits, wrapping at 340 points otherwise.
    private var textWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: 13, weight: isFailure ? .regular : .medium)
        let natural = (message as NSString).size(withAttributes: [.font: font]).width
        return max(min(ceil(natural) + 2, 340), isFailure ? 200 : 0)
    }

    private var message: String {
        switch status {
        case .working(let text), .success(let text), .failure(let text): text
        }
    }
}

/// Menu-style vibrancy that stays vivid although the panel is never active.
private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
