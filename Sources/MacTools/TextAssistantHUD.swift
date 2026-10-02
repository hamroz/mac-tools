import AppKit
import Combine
import SwiftUI

/// A small status bubble next to the pointer. It never takes focus or clicks,
/// so the app being edited keeps its selection and receives the paste.
@MainActor
final class TextAssistantHUD: TextAssistantFeedback {
    private final class Model: ObservableObject {
        @Published var status: TextAssistantStatus = .working("")
    }

    private let model = Model()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show(_ status: TextAssistantStatus) {
        let panel = panel ?? makePanel()
        self.panel = panel
        let isNew = !panel.isVisible
        model.status = status
        hideTask?.cancel()
        if let size = panel.contentView?.fittingSize { panel.setContentSize(size) }
        if isNew { position(panel) }
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        switch status {
        case .working: break
        case .success: scheduleHide(after: 1.2)
        case .failure: scheduleHide(after: 5)
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
                context.duration = 0.2
                panel.animator().alphaValue = 0
            }
            guard !Task.isCancelled else { return }
            panel.orderOut(nil)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let hosting = NSHostingView(rootView: HUDView(model: model))
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        return panel
    }

    /// Just below and to the right of the pointer, kept on its screen.
    private func position(_ panel: NSPanel) {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        var origin = CGPoint(x: pointer.x + 14, y: pointer.y - 18 - panel.frame.height)
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - panel.frame.width - 8)
            origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - panel.frame.height - 8)
        }
        panel.setFrameOrigin(origin)
    }

    private struct HUDView: View {
        @ObservedObject var model: Model

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                icon
                Text(message)
                    .font(.callout)
                    .frame(width: textWidth, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
        }

        @ViewBuilder private var icon: some View {
            switch model.status {
            case .working: ProgressView().controlSize(.small)
            case .success: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failure: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }

        /// One line when it fits, wrapping at 320 points otherwise.
        private var textWidth: CGFloat {
            let font = NSFont.preferredFont(forTextStyle: .callout)
            let natural = (message as NSString).size(withAttributes: [.font: font]).width
            return min(ceil(natural) + 2, 320)
        }

        private var message: String {
            switch model.status {
            case .working(let text), .success(let text), .failure(let text): text
            }
        }
    }
}
