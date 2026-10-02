import AppKit
import MacToolsCore
import SwiftUI

/// Press or build a combination; see whether it's free as a global shortcut.
struct ShortcutCheckView: View {
    @ObservedObject var store: ShortcutsStore
    let pauseHotKeys: (Bool) -> Void
    /// A combination to check right away.
    var initialCombo: KeyCombo?

    @State private var modifiers: ShortcutModifiers = [.control, .option]
    @State private var keyCode: UInt16?
    @StateObject private var recorder = ComboRecorder()

    private var combo: KeyCombo? {
        keyCode.map { KeyCombo(keyCode: $0, modifiers: modifiers) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Check a Shortcut").font(.title2.weight(.semibold))
                    Text("Press a combination, or build it below, to see whether it’s free to use as a global shortcut.")
                        .foregroundStyle(.secondary)
                }
                recorderBox
                builder
                if let combo {
                    let result = ShortcutChecker.check(combo, in: store.catalog)
                    VerdictView(result: result)
                    matches(result)
                    alternatives(for: combo)
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            if let initialCombo, keyCode == nil {
                keyCode = initialCombo.keyCode
                modifiers = initialCombo.modifiers
            }
            recorder.onRecord = { combo in
                keyCode = combo.keyCode
                modifiers = combo.modifiers
            }
            recorder.onRecordingChange = pauseHotKeys
            store.refreshMacToolsShortcuts()
        }
        .onDisappear { recorder.stop() }
    }

    // MARK: Input

    private var recorderBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                recorder.isRecording ? recorder.stop() : recorder.start()
            } label: {
                HStack {
                    Image(systemName: recorder.isRecording ? "record.circle.fill" : "keyboard")
                        .foregroundStyle(recorder.isRecording ? .red : .secondary)
                    Text(recorderTitle)
                        .font(.system(.title3, design: .rounded).weight(.medium))
                    Spacer()
                    if recorder.isRecording {
                        Text("Esc to cancel").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(recorder.isRecording ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: recorder.isRecording ? 2 : 1)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text("If another app reacts when you press a combination, it never reaches Mac Tools. That combination is taken; build it below to see by what.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var recorderTitle: String {
        if recorder.isRecording {
            return recorder.heldModifiers.isEmpty ? "Press a combination…" : recorder.heldModifiers.symbols + "…"
        }
        return combo?.displayString ?? "Click to record a combination"
    }

    private var builder: some View {
        HStack(spacing: 8) {
            ForEach(ModifierChoice.allCases) { choice in
                let isOn = modifiers.contains(choice.modifier)
                Button {
                    binding(for: choice.modifier).wrappedValue.toggle()
                } label: {
                    Text(choice.symbol)
                        .font(.system(.title3, design: .rounded).weight(.medium))
                        .frame(width: 40, height: 30)
                        .foregroundStyle(isOn ? Color.white : Color.primary)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(choice.name)
                .accessibilityLabel(choice.name)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
            Text("+").foregroundStyle(.secondary)
            Picker("Key", selection: $keyCode) {
                Text("Choose a key").tag(UInt16?.none)
                ForEach(KeyNames.pickerKeys, id: \.self) { code in
                    Text(KeyNames.name(for: code)).tag(Optional(code))
                }
            }
            .labelsHidden()
            .frame(width: 150)
        }
    }

    private func binding(for modifier: ShortcutModifiers) -> Binding<Bool> {
        Binding(
            get: { modifiers.contains(modifier) },
            set: { isOn in if isOn { modifiers.insert(modifier) } else { modifiers.remove(modifier) } }
        )
    }

    // MARK: Results

    @ViewBuilder
    private func matches(_ result: ShortcutCheckResult) -> some View {
        matchSection("Global shortcuts using it", result.globalOwners, showSource: true)
        matchSection("Standard shortcut", result.standardMatches, showSource: false)
        matchSection("Used inside apps", result.inAppMatches, showSource: true)
        matchSection("Also matches (not active)", result.inactiveMatches, showSource: true)
    }

    @ViewBuilder
    private func matchSection(_ title: String, _ entries: [ShortcutEntry], showSource: Bool) -> some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                VStack(spacing: 0) {
                    ForEach(entries) { entry in
                        ShortcutRow(entry: entry, showsSource: showSource)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                        if entry.id != entries.last?.id { Divider() }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.background.secondary))
            }
        }
    }

    private func alternatives(for combo: KeyCombo) -> some View {
        let results = ShortcutChecker.alternatives(for: combo, in: store.catalog)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Same key, other modifiers").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(results) { result in
                    Button {
                        keyCode = result.combo.keyCode
                        modifiers = result.combo.modifiers
                    } label: {
                        HStack(spacing: 6) {
                            Circle().fill(result.verdict.tint).frame(width: 8, height: 8)
                            Text(result.combo.displayString).font(.system(.body, design: .rounded).weight(.medium))
                            Spacer(minLength: 0)
                            Text(result.verdict.shortTitle).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.background.secondary))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Check \(result.combo.displayString)")
                }
            }
        }
    }
}

private enum ModifierChoice: CaseIterable, Identifiable {
    case control, option, shift, command

    var id: Self { self }
    var modifier: ShortcutModifiers {
        switch self {
        case .control: .control
        case .option: .option
        case .shift: .shift
        case .command: .command
        }
    }
    var symbol: String {
        switch self {
        case .control: "⌃"
        case .option: "⌥"
        case .shift: "⇧"
        case .command: "⌘"
        }
    }
    var name: String {
        switch self {
        case .control: "Control"
        case .option: "Option"
        case .shift: "Shift"
        case .command: "Command"
        }
    }
}

private struct VerdictView: View {
    let result: ShortcutCheckResult

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            KeyCaps(combo: result.combo, large: true)
            VStack(alignment: .leading, spacing: 4) {
                Label(result.verdict.title, systemImage: result.verdict.symbol)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(result.verdict.tint)
                Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(result.verdict.tint.opacity(0.12)))
    }

    private var message: String {
        switch result.verdict {
        case .takenGlobally:
            let owners = result.globalOwners.map { "\($0.action) (\($0.source.name))" }
            return "Already a global shortcut: " + owners.joined(separator: ", ") + "."
        case .standard:
            let action = result.standardMatches.first?.action ?? "a standard command"
            return "Nearly every app uses it for \(action). A global shortcut here would break that everywhere."
        case .notUsable(let reason):
            return reason + "."
        case .usedInApps:
            return "No global shortcut uses it, but some apps do in their menus. A global shortcut would take over while they’re in front."
        case .free:
            return "No shortcut Mac Tools can see uses it."
        }
    }
}

extension ShortcutVerdict {
    var title: String {
        switch self {
        case .takenGlobally: "Taken"
        case .standard: "Standard shortcut"
        case .notUsable: "Not usable globally"
        case .usedInApps: "Free globally, used inside apps"
        case .free: "Free"
        }
    }

    var shortTitle: String {
        switch self {
        case .takenGlobally: "Taken"
        case .standard: "Standard"
        case .notUsable: "Not usable"
        case .usedInApps: "In apps"
        case .free: "Free"
        }
    }

    var symbol: String {
        switch self {
        case .takenGlobally, .standard, .notUsable: "xmark.octagon.fill"
        case .usedInApps: "exclamationmark.triangle.fill"
        case .free: "checkmark.seal.fill"
        }
    }

    var tint: Color {
        switch self {
        case .takenGlobally, .standard, .notUsable: .red
        case .usedInApps: .yellow
        case .free: .green
        }
    }
}

/// Records one key-down in Mac Tools' own window with a local event monitor.
@MainActor
final class ComboRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var heldModifiers: ShortcutModifiers = []
    var onRecord: ((KeyCombo) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?
    private var monitor: Any?

    func start() {
        guard !isRecording else { return }
        isRecording = true
        heldModifiers = []
        onRecordingChange?(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            let isFlagsChange = event.type == .flagsChanged
            let keyCode = event.keyCode
            let flags = Int(event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue)
            let swallowed = MainActor.assumeIsolated {
                self?.handle(isFlagsChange: isFlagsChange, keyCode: keyCode, flags: flags) ?? false
            }
            return swallowed ? nil : event
        }
    }

    func stop() {
        guard isRecording else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        heldModifiers = []
        onRecordingChange?(false)
    }

    /// Returns true to swallow the event; every event is swallowed while recording.
    private func handle(isFlagsChange: Bool, keyCode: UInt16, flags: Int) -> Bool {
        guard isRecording else { return false }
        let modifiers = ShortcutModifiers(cocoa: flags)
        if isFlagsChange {
            heldModifiers = modifiers.subtracting(.function)
            return true
        }
        if keyCode == 53, modifiers.subtracting(.function).isEmpty {
            stop()
            return true
        }
        onRecord?(KeyCombo(keyCode: keyCode, modifiers: modifiers))
        stop()
        return true
    }
}
