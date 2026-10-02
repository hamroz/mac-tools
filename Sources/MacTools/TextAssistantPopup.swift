import AppKit
import Combine
import MacToolsCore
import SwiftUI

/// What the popup shows and how keys move through it. Kept apart from the
/// panel so the keyboard behavior is testable.
@MainActor
final class TextAssistantPopupModel: ObservableObject {
    enum Column: Equatable {
        case mode
        case tone
    }

    enum Key: Equatable {
        case up, down, left, right, tab, backTab, enter, escape
        case character(Character)
    }

    enum Outcome: Equatable {
        case handled
        case ignored
        case run(modeID: String, toneID: String)
        case cancel
    }

    struct Item: Identifiable, Equatable {
        let id: String
        let name: String
    }

    @Published private(set) var modes: [Item] = []
    @Published private(set) var tones: [Item] = []
    @Published var modeIndex = 0
    @Published var toneIndex = 0
    @Published var column: Column = .mode
    /// nil while the selection is still being read.
    @Published private(set) var selectionText: String?

    func load(config: TextAssistantConfig, modeID: String, toneID: String) {
        modes = config.modes.map { Item(id: $0.id, name: $0.name) }
        tones = config.tones.map { Item(id: $0.id, name: $0.name) }
        modeIndex = modes.firstIndex { $0.id == modeID } ?? 0
        toneIndex = tones.firstIndex { $0.id == toneID } ?? 0
        column = .mode
        selectionText = nil
    }

    func setSelection(_ text: String) { selectionText = text }

    var isReady: Bool { selectionText != nil && !modes.isEmpty && !tones.isEmpty }

    var currentChoice: (modeID: String, toneID: String)? {
        guard modes.indices.contains(modeIndex), tones.indices.contains(toneIndex) else { return nil }
        return (modes[modeIndex].id, tones[toneIndex].id)
    }

    func handle(_ key: Key) -> Outcome {
        switch key {
        case .escape:
            return .cancel
        case .enter:
            guard isReady, let choice = currentChoice else { return .handled }
            return .run(modeID: choice.modeID, toneID: choice.toneID)
        case .up: move(-1)
        case .down: move(1)
        case .left, .backTab: column = .mode
        case .right: column = .tone
        case .tab: column = column == .mode ? .tone : .mode
        case .character(let character):
            guard jump(to: character) else { return .ignored }
        }
        return .handled
    }

    func choose(_ column: Column, index: Int) {
        self.column = column
        switch column {
        case .mode: if modes.indices.contains(index) { modeIndex = index }
        case .tone: if tones.indices.contains(index) { toneIndex = index }
        }
    }

    private func move(_ offset: Int) {
        switch column {
        case .mode: modeIndex = Self.clamp(modeIndex + offset, count: modes.count)
        case .tone: toneIndex = Self.clamp(toneIndex + offset, count: tones.count)
        }
    }

    /// 1–9 picks by position; a letter picks the next item starting with it.
    private func jump(to character: Character) -> Bool {
        let items = column == .mode ? modes : tones
        let current = column == .mode ? modeIndex : toneIndex
        var target: Int?
        if let digit = character.wholeNumberValue, (1...9).contains(digit), digit <= items.count {
            target = digit - 1
        } else if character.isLetter {
            let letter = String(character).lowercased()
            let order = items.indices.map { (current + 1 + $0) % items.count }
            target = order.first { items[$0].name.lowercased().hasPrefix(letter) }
        }
        guard let target else { return false }
        choose(column, index: target)
        return true
    }

    private static func clamp(_ index: Int, count: Int) -> Int {
        min(max(index, 0), max(count - 1, 0))
    }
}

// MARK: - Panel

/// A Spotlight-style panel near the pointer. It never activates Mac Tools, so
/// the app being edited stays frontmost and gets the paste afterwards; it takes
/// the keyboard only once the selection has been read.
@MainActor
final class TextAssistantPopup: NSObject, NSWindowDelegate {
    let model = TextAssistantPopupModel()
    var onRun: ((_ modeID: String, _ toneID: String) -> Void)?
    var onCancel: (() -> Void)?

    private(set) var panel: KeyablePanel?
    private var hosting: NSHostingController<PopupView>?
    private var keyMonitor: Any?
    private var isClosing = false

    var isVisible: Bool { panel?.isVisible == true }

    /// Shows the panel without taking the keyboard, so ⌘C still reaches the app.
    func show(config: TextAssistantConfig, modeID: String, toneID: String) {
        model.load(config: config, modeID: modeID, toneID: toneID)
        let panel = panel ?? makePanel()
        self.panel = panel
        resize(panel)
        position(panel)
        isClosing = false
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    /// The selection is in; now take the keyboard.
    func present(selection: String) {
        guard let panel, panel.isVisible else { return }
        model.setSelection(selection)
        resize(panel, keepingTop: true)
        installKeyMonitor()
        panel.makeKey()
    }

    func close() {
        guard let panel, panel.isVisible, !isClosing else { return }
        isClosing = true
        removeKeyMonitor()
        // Ordering out hands the keyboard back to the app being edited before anything is pasted.
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        // Clicking anywhere else cancels, like Spotlight.
        guard !isClosing, panel?.isVisible == true else { return }
        close()
        onCancel?()
    }

    private func finish(_ outcome: TextAssistantPopupModel.Outcome) {
        switch outcome {
        case .run(let modeID, let toneID):
            close()
            onRun?(modeID, toneID)
        case .cancel:
            close()
            onCancel?()
        case .handled, .ignored:
            break
        }
    }

    private func makePanel() -> KeyablePanel {
        let panel = KeyablePanel(
            contentRect: CGRect(x: 0, y: 0, width: 480, height: 300),
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
        let hosting = NSHostingController(rootView: makeView())
        hosting.sizingOptions = []
        panel.contentViewController = hosting
        self.hosting = hosting
        return panel
    }

    private func makeView() -> PopupView {
        PopupView(model: model, run: { [weak self] in
            guard let self else { return }
            self.finish(self.model.handle(.enter))
        }, runChoice: { [weak self] column, index in
            guard let self else { return }
            self.model.choose(column, index: index)
            self.finish(self.model.handle(.enter))
        })
    }

    private func resize(_ panel: NSPanel, keepingTop: Bool = false) {
        guard let hosting else { return }
        let size = hosting.sizeThatFits(in: CGSize(width: 480, height: 2_000))
        let top = panel.frame.maxY
        panel.setContentSize(size)
        if keepingTop { panel.setFrameOrigin(CGPoint(x: panel.frame.minX, y: top - size.height)) }
    }

    /// Below and to the right of the pointer, kept on its screen.
    private func position(_ panel: NSPanel) {
        let pointer = NSEvent.mouseLocation
        let size = panel.frame.size
        var origin = CGPoint(x: pointer.x - 24, y: pointer.y - 16 - size.height)
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
            // No room below: open above the pointer.
            if origin.y < visible.minY + 8 { origin.y = min(pointer.y + 16, visible.maxY - size.height - 8) }
        }
        panel.setFrameOrigin(origin)
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, panel.isKeyWindow else { return event }
            guard let key = Self.key(for: event) else { return event }
            let outcome = self.model.handle(key)
            if outcome == .ignored { return event }
            self.finish(outcome)
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private static func key(for event: NSEvent) -> TextAssistantPopupModel.Key? {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        guard modifiers.isEmpty else { return nil }
        switch event.keyCode {
        case 126: return .up
        case 125: return .down
        case 123: return .left
        case 124: return .right
        case 48: return event.modifierFlags.contains(.shift) ? .backTab : .tab
        case 36, 76: return .enter
        case 53: return .escape
        default:
            return event.charactersIgnoringModifiers?.first.map { .character($0) }
        }
    }
}

/// A borderless panel that can take the keyboard without activating Mac Tools.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - View

struct PopupView: View {
    @ObservedObject var model: TextAssistantPopupModel
    let run: () -> Void
    let runChoice: (TextAssistantPopupModel.Column, Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            HStack(alignment: .top, spacing: 10) {
                column("Mode", items: model.modes, selected: model.modeIndex, kind: .mode)
                column("Tone", items: model.tones, selected: model.toneIndex, kind: .tone)
            }
            footer
        }
        .padding(14)
        .frame(width: 480)
        .background(PopupMaterial())
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
        .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(.teal)
                Text("Text Assistant")
                    .font(.headline)
                Spacer()
                if let text = model.selectionText {
                    Text("\(text.count.formatted()) characters")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 6) {
                if model.selectionText == nil { ProgressView().controlSize(.mini) }
                Text(snippet)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
        }
    }

    private var snippet: String {
        guard let text = model.selectionText else { return "Reading the selection…" }
        return text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    private func column(_ title: String, items: [TextAssistantPopupModel.Item], selected: Int,
                        kind: TextAssistantPopupModel.Column) -> some View {
        let focused = model.column == kind
        return VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(focused ? .primary : .secondary)
                .padding(.leading, 8)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            row(item.name, index: index, isSelected: index == selected, focused: focused)
                                .id(item.id)
                                .onTapGesture(count: 2) { runChoice(kind, index) }
                                .onTapGesture { model.choose(kind, index: index) }
                        }
                    }
                }
                .scrollIndicators(.never)
                .frame(maxHeight: 260)
                .onChange(of: selected) { _, index in
                    if items.indices.contains(index) { proxy.scrollTo(items[index].id) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(focused ? 0.05 : 0.02))
        )
    }

    private func row(_ name: String, index: Int, isSelected: Bool, focused: Bool) -> some View {
        HStack(spacing: 6) {
            Text(name)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected && focused ? Color.white : .primary)
            Spacer(minLength: 4)
            if index < 9 {
                Text("\(index + 1)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(isSelected && focused ? Color.white.opacity(0.75) : Color.secondary.opacity(0.6))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? (focused ? Color.accentColor : Color.primary.opacity(0.12)) : .clear)
        )
    }

    private var footer: some View {
        HStack(spacing: 12) {
            hint("↑↓", "choose")
            hint("←→", "switch")
            hint("esc", "cancel")
            Spacer()
            Button(action: run) {
                Text("Run")
                    .frame(minWidth: 44)
            }
            .buttonStyle(.borderedProminent)
            .help("Return")
            .disabled(!model.isReady)
        }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.caption2.weight(.semibold).monospaced())
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.1)))
            Text(label)
                .font(.caption)
        }
        .foregroundStyle(.secondary)
    }
}

/// Popover-style vibrancy that stays vivid although Mac Tools is never active.
private struct PopupMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
