import Carbon.HIToolbox
import Combine
import Foundation
import MacToolsCore

@MainActor
final class HotKeyManager: ObservableObject {
    @Published private(set) var preset: HotKeyPreset
    @Published private(set) var errorMessage: String?

    var onPressed: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private let defaults: UserDefaults
    private let defaultsKey = "desktopStickies.hotKeyPreset"

    private nonisolated(unsafe) static weak var active: HotKeyManager?
    nonisolated static let signature: OSType = 0x4D544C53 // MTLS

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let value = defaults.string(forKey: defaultsKey), let saved = HotKeyPreset(rawValue: value) {
            preset = saved
        } else {
            preset = .controlOptionN
        }
    }

    func start() {
        Self.active = self
        installHandlerIfNeeded()
        registerCurrentPreset()
    }

    func stop() {
        unregister()
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
        if Self.active === self { Self.active = nil }
    }

    func setPreset(_ newPreset: HotKeyPreset) {
        guard newPreset != preset else { return }
        preset = newPreset
        defaults.set(newPreset.rawValue, forKey: defaultsKey)
        registerCurrentPreset()
    }

    private func installHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ in
                // Other hotkey users (Text Assistant's shortcuts) share this event
                // target, so only claim presses of this manager's own hotkey.
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
                )
                guard status == noErr, hotKeyID.signature == HotKeyManager.signature else {
                    return OSStatus(eventNotHandledErr)
                }
                Task { @MainActor in
                    HotKeyManager.active?.onPressed?()
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            &eventHandlerRef
        )
        if status != noErr {
            errorMessage = "The global shortcut listener could not be started (error \(status))."
        }
    }

    private func registerCurrentPreset() {
        unregister()
        // Do not hide a listener-installation failure or register while stopped.
        guard eventHandlerRef != nil else { return }
        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(
            preset.keyCode,
            carbonModifiers(for: preset),
            identifier,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        if status == noErr {
            hotKeyRef = reference
            errorMessage = nil
        } else {
            errorMessage = "\(preset.displayName) is unavailable. New Note remains available from the menu (error \(status))."
        }
    }

    private func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    private func carbonModifiers(for preset: HotKeyPreset) -> UInt32 {
        preset.modifiers.reduce(into: UInt32(0)) { result, modifier in
            switch modifier {
            case .control: result |= UInt32(controlKey)
            case .option: result |= UInt32(optionKey)
            case .shift: result |= UInt32(shiftKey)
            case .command: result |= UInt32(cmdKey)
            }
        }
    }
}
