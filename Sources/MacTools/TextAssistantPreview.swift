import AppKit
import Combine
import SwiftUI

enum PreviewDecision: Equatable {
    case replace
    case copy
    case cancel
}

/// Shows a result before it replaces anything; the app's panel, a recorder in tests.
@MainActor
protocol TextAssistantPreviewing: AnyObject {
    /// Called when the user cancels while the model is still writing.
    var onCancel: (() -> Void)? { get set }
    func begin(title: String, canReplace: Bool)
    func update(_ text: String)
    /// Shows the final text and waits for the user. A cancelled task answers `.cancel`.
    func finish(_ text: String) async -> PreviewDecision
    func fail(_ message: String)
    func dismiss()
}

/// What the preview shows. A plain value, rendered and measured in one step,
/// so the panel is always sized to what is on screen.
struct PreviewState: Equatable {
    enum Phase: Equatable {
        case working
        case ready
        case failed(String)
    }

    var title = ""
    var text = ""
    var phase: Phase = .working
    var canReplace = true
}

/// A panel near the pointer that streams the result in. It takes the keyboard
/// without activating Mac Tools, so the edited app stays frontmost for the paste.
@MainActor
final class TextAssistantPreview: NSObject, TextAssistantPreviewing, NSWindowDelegate {
    private(set) var state = PreviewState()
    var onCancel: (() -> Void)?

    private(set) var panel: KeyablePanel?
    private var hosting: NSHostingController<PreviewView>?
    private var keyMonitor: Any?
    private var decision: CheckedContinuation<PreviewDecision, Never>?
    private var isClosing = false

    func begin(title: String, canReplace: Bool) {
        resolve(.cancel)
        state = PreviewState(title: title, canReplace: canReplace)
        let panel = panel ?? makePanel()
        self.panel = panel
        render(keepingTop: false)
        position(panel)
        isClosing = false
        panel.orderFrontRegardless()
        installKeyMonitor()
        // The selection was already read, so the panel can take the keyboard now.
        panel.makeKey()
    }

    func update(_ text: String) {
        guard state.phase == .working, text != state.text else { return }
        state.text = text
        render(keepingTop: true)
    }

    func finish(_ text: String) async -> PreviewDecision {
        state.text = text
        state.phase = .ready
        render(keepingTop: true)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: .cancel); return }
                decision = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resolve(.cancel) }
        }
    }

    func fail(_ message: String) {
        state.phase = .failed(message)
        render(keepingTop: true)
    }

    func dismiss() {
        resolve(.cancel)
        close()
    }

    func windowDidResignKey(_ notification: Notification) {
        // Clicking anywhere else dismisses the preview, like Spotlight.
        guard !isClosing, panel?.isVisible == true else { return }
        cancelByUser()
    }

    private func choose(_ choice: PreviewDecision) {
        switch state.phase {
        case .working:
            if choice == .cancel { cancelByUser() }
        case .ready:
            if choice == .replace, !state.canReplace { return choose(.copy) }
            close()
            resolve(choice)
        case .failed:
            if choice == .cancel || choice == .replace { close() }
        }
    }

    private func cancelByUser() {
        close()
        resolve(.cancel)
        onCancel?()
    }

    private func resolve(_ choice: PreviewDecision) {
        decision?.resume(returning: choice)
        decision = nil
    }

    private func close() {
        guard let panel, panel.isVisible, !isClosing else { return }
        isClosing = true
        removeKeyMonitor()
        panel.orderOut(nil)
    }

    private func makePanel() -> KeyablePanel {
        let panel = KeyablePanel(
            contentRect: CGRect(x: 0, y: 0, width: 520, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .modalPanel
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.delegate = self
        let hosting = NSHostingController(rootView: PreviewView(state: state, choose: { _ in }))
        hosting.sizingOptions = []
        panel.contentViewController = hosting
        self.hosting = hosting
        return panel
    }

    private func render(keepingTop: Bool) {
        guard let panel, let hosting else { return }
        hosting.rootView = PreviewView(state: state, choose: { [weak self] in self?.choose($0) })
        let size = hosting.sizeThatFits(in: CGSize(width: 520, height: 2_000))
        guard size != panel.frame.size else { return }
        let top = panel.frame.maxY
        panel.setContentSize(size)
        if keepingTop { panel.setFrameOrigin(CGPoint(x: panel.frame.minX, y: top - size.height)) }
    }

    private func position(_ panel: NSPanel) {
        let pointer = NSEvent.mouseLocation
        // Leave room for the result to grow downward.
        let size = CGSize(width: panel.frame.width, height: max(panel.frame.height, 260))
        var origin = CGPoint(x: pointer.x - 24, y: pointer.y - 16 - panel.frame.height)
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
            if pointer.y - 16 - size.height < visible.minY + 8 {
                origin.y = visible.minY + 8 + size.height - panel.frame.height
            }
        }
        panel.setFrameOrigin(origin)
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, panel.isKeyWindow else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .control, .option])
            switch (event.keyCode, modifiers) {
            case (53, []): self.choose(.cancel)
            case (36, []), (76, []): self.choose(.replace)
            case (8, [.command]): self.choose(.copy)
            default: return event
            }
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

struct PreviewView: View {
    let state: PreviewState
    let choose: (PreviewDecision) -> Void

    /// Results taller than this scroll inside the panel.
    private static let maxTextHeight: CGFloat = 320
    private static let textWidth: CGFloat = 520 - 28 - 20

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "wand.and.stars").foregroundStyle(.teal)
                Text(state.title).font(.headline)
                Spacer()
                if state.phase == .working { ProgressView().controlSize(.small) }
            }
            content
            footer
        }
        .padding(14)
        .frame(width: 520)
        .background(PreviewMaterial())
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var content: some View {
        if case .failed(let message) = state.phase {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Group {
                if isLong {
                    ScrollView { resultText }
                        .frame(height: Self.maxTextHeight)
                } else {
                    resultText
                }
            }
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
            if !state.canReplace {
                Text("This text can’t be edited where it is, so the result can only be copied.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var resultText: some View {
        Text(state.text.isEmpty ? "Working…" : state.text)
            .font(.system(size: 14))
            .foregroundStyle(state.text.isEmpty ? .secondary : .primary)
            .textSelection(.enabled)
            .frame(width: Self.textWidth, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
    }

    private var isLong: Bool {
        let bounds = (state.text as NSString).boundingRect(
            with: CGSize(width: Self.textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 14)]
        )
        return bounds.height + 20 > Self.maxTextHeight
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            if case .failed = state.phase {
                Button("Close") { choose(.cancel) }
            } else {
                Button("Cancel") { choose(.cancel) }
                    .help("Esc")
                if state.canReplace {
                    Button("Copy") { choose(.copy) }
                        .help("⌘C")
                        .disabled(state.phase != .ready)
                    Button("Replace") { choose(.replace) }
                        .buttonStyle(.borderedProminent)
                        .help("Return")
                        .disabled(state.phase != .ready)
                } else {
                    Button("Copy") { choose(.copy) }
                        .buttonStyle(.borderedProminent)
                        .help("Return or ⌘C")
                        .disabled(state.phase != .ready)
                }
            }
        }
    }
}

private struct PreviewMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
