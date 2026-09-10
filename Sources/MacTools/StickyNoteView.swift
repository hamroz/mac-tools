import AppKit
import MacToolsCore
import SwiftUI

struct StickyNoteView: View {
    let noteID: UUID
    let focusInitially: Bool
    let onTextChanged: (String) -> Void
    let onPaletteChanged: (NotePalette) -> Void
    let onDelete: () -> Void

    @State private var text: String
    @State private var palette: NotePalette
    @State private var isHovering = false
    @FocusState private var editorFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    init(
        note: StickyNoteRecord,
        focusInitially: Bool,
        onTextChanged: @escaping (String) -> Void,
        onPaletteChanged: @escaping (NotePalette) -> Void,
        onDelete: @escaping () -> Void
    ) {
        noteID = note.id
        self.focusInitially = focusInitially
        self.onTextChanged = onTextChanged
        self.onPaletteChanged = onPaletteChanged
        self.onDelete = onDelete
        _text = State(initialValue: note.text)
        _palette = State(initialValue: note.palette)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(palette.backgroundColor(for: colorScheme))

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    WindowDragArea(showGrip: isHovering, gripColor: NSColor(palette.accentColor(for: colorScheme)))
                        .frame(maxWidth: .infinity)

                    controls
                        .padding(.horizontal, 8)
                        .opacity(isHovering ? 1 : 0)
                        .allowsHitTesting(isHovering)
                        .accessibilityHidden(!isHovering)
                        .animation(.easeOut(duration: 0.12), value: isHovering)
                }
                .frame(height: 36)

                TextEditor(text: $text)
                    .font(.system(size: 15, weight: .regular, design: .rounded))
                    .foregroundStyle(palette.foregroundColor(for: colorScheme))
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .focused($editorFocused)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                    .accessibilityLabel("Note text")
            }

            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(-45))
                        .foregroundStyle(palette.accentColor(for: colorScheme).opacity(0.5))
                        .padding(7)
                        .accessibilityHidden(true)
                }
            }
            .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { isHovering = $0 }
        .onChange(of: text) { _, newText in onTextChanged(newText) }
        .onAppear {
            if focusInitially {
                Task { @MainActor in editorFocused = true }
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 5) {
            Menu {
                ForEach(NotePalette.allCases) { option in
                    Button {
                        palette = option
                        onPaletteChanged(option)
                    } label: {
                        Label(option.displayName, systemImage: option == palette ? "checkmark.circle.fill" : "circle.fill")
                    }
                }
            } label: {
                Image(systemName: "circle.lefthalf.filled")
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Note color")
            .accessibilityLabel("Choose note color")

            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("Move to Recently Deleted")
            .accessibilityLabel("Move note to Recently Deleted")
        }
        .foregroundStyle(palette.accentColor(for: colorScheme))
    }
}

private struct WindowDragArea: NSViewRepresentable {
    let showGrip: Bool
    let gripColor: NSColor

    func makeNSView(context: Context) -> DraggingView {
        DraggingView()
    }

    func updateNSView(_ nsView: DraggingView, context: Context) {
        nsView.showGrip = showGrip
        nsView.gripColor = gripColor
    }
}

final class DraggingView: NSView {
    // Hide only the drawing, not the native view: the invisible top strip
    // must remain draggable and must still receive hover/cursor events.
    var showGrip = false {
        didSet { if showGrip != oldValue { needsDisplay = true } }
    }
    var gripColor: NSColor = .secondaryLabelColor {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityLabel("Move note")
        setAccessibilityHelp("Drag this handle to move the note around the desktop.")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // The drag region is a sibling of the editor and controls, with its own
    // native hit target. Clicking it must work even while another app is active.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard showGrip else { return }
        gripColor.setFill()
        for x in [CGFloat(15), 19] {
            for offset in [CGFloat(-4), 0, 4] {
                NSBezierPath(ovalIn: NSRect(x: x, y: bounds.midY + offset - 1, width: 2, height: 2)).fill()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        NSCursor.closedHand.push()
        defer { NSCursor.pop() }
        window?.performDrag(with: event)
    }
}
