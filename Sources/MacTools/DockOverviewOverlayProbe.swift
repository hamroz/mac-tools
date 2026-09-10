import AppKit
import Foundation

/// Pure transition logic for the overlay probe. Keeping it separate from the
/// window-list I/O lets the pairing rules be exercised deterministically in
/// tests, where synthesizing real Dock transitions is not possible.
struct DockOverviewWindowSignal {
    private(set) var isMissionControlActive = false
    private var seenLayer18: Set<Int> = []
    private var seenLayer20: Set<Int> = []
    private var candidateTick: Int?
    private var candidateSawLayer18 = false
    private var candidateSawLayer20 = false
    private let pairingWindow: Int

    init(pairingWindow: Int = 5) {
        self.pairingWindow = pairingWindow
    }

    /// Records the windows present at launch or after a Dock restart without
    /// treating them as a transition.
    mutating func reset(layer18: Set<Int>, layer20: Set<Int>) {
        seenLayer18 = layer18
        seenLayer20 = layer20
        isMissionControlActive = false
        clearCandidate()
    }

    mutating func observe(layer18: Set<Int>, layer20: Set<Int>, tick: Int) -> Bool {
        let appeared18 = layer18.subtracting(seenLayer18)
        let appeared20 = layer20.subtracting(seenLayer20)
        seenLayer18 = layer18
        seenLayer20 = layer20

        if isMissionControlActive {
            if layer18.isEmpty {
                isMissionControlActive = false
                clearCandidate()
            }
            return isMissionControlActive
        }

        if let candidateTick, tick - candidateTick > pairingWindow { clearCandidate() }
        if candidateSawLayer18, layer18.isEmpty { clearCandidate() }
        if !appeared18.isEmpty || !appeared20.isEmpty {
            if candidateTick == nil { candidateTick = tick }
            if !appeared18.isEmpty { candidateSawLayer18 = true }
            if !appeared20.isEmpty { candidateSawLayer20 = true }
            if candidateSawLayer18, candidateSawLayer20 {
                isMissionControlActive = true
                clearCandidate()
            }
        }
        return isMissionControlActive
    }

    private mutating func clearCandidate() {
        candidateTick = nil
        candidateSawLayer18 = false
        candidateSawLayer20 = false
    }
}

/// Watches the Dock's own full-screen windows so notes can disappear on the
/// first Mission Control animation frame. Mission Control and App Exposé create
/// a layer-18 window together with a new layer-20 window; Show Desktop creates
/// the layer-18 window alone, so notes stay visible there. The AX notifications
/// that `DockOverviewMonitor` uses arrive only after the animation has started,
/// which is what caused the visible flash.
@MainActor
final class DockOverviewOverlayProbe {
    private let presentation: DesktopPresentation
    private var signal = DockOverviewWindowSignal()
    private var maintenance: Task<Void, Never>?
    private var activity: NSObjectProtocol?
    private var dockPID: pid_t?
    private var tick = 0

    init(presentation: DesktopPresentation) { self.presentation = presentation }

    func start() {
        guard maintenance == nil else { return }
        maintenance = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.poll()
                let active = self.presentation.pinsNotes || self.signal.isMissionControlActive
                do { try await Task.sleep(for: active ? .milliseconds(33) : .milliseconds(250)) }
                catch { return }
            }
        }
    }

    func stop() {
        maintenance?.cancel()
        maintenance = nil
        setActivity(false)
        dockPID = nil
        signal.reset(layer18: [], layer20: [])
        presentation.updateOverlay(hidesNotes: false)
    }

    private func poll() {
        tick += 1
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
                .first?.processIdentifier,
              let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            return
        }
        let overlay = Self.overlayWindows(in: windows, dockPID: pid)
        if dockPID != pid {
            dockPID = pid
            signal.reset(layer18: overlay.layer18, layer20: overlay.layer20)
        }
        presentation.markProbeReady()
        let wasActive = signal.isMissionControlActive
        let active = signal.observe(layer18: overlay.layer18, layer20: overlay.layer20, tick: tick)
        if active != wasActive {
            setActivity(active)
            if !active, presentation.state.hidesNotes {
                // The Dock's AX exit notification can be lost. The probe watched
                // the overlay end, so release the fallback hide state as well.
                presentation.update(.inactive)
            }
        }
        presentation.updateOverlay(hidesNotes: active)
    }

    /// While the overlay is on screen the notes are transparent, so the app has
    /// no visible windows; a user-initiated activity keeps this poller awake
    /// until the overlay ends.
    private func setActivity(_ active: Bool) {
        if active, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "Hide notes while Mission Control is on screen")
        } else if !active, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    private static func overlayWindows(in windows: [[String: Any]],
                                       dockPID: pid_t) -> (layer18: Set<Int>, layer20: Set<Int>) {
        var layer18: Set<Int> = []
        var layer20: Set<Int> = []
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == dockPID,
                  let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  layer == 18 || layer == 20,
                  let number = (window[kCGWindowNumber as String] as? NSNumber)?.intValue,
                  isFullScreen(window) else { continue }
            if layer == 18 { layer18.insert(number) } else { layer20.insert(number) }
        }
        return (layer18, layer20)
    }

    /// Excludes the Dock's own bar and other small helper windows, so a bar
    /// reveal while Show Desktop is active cannot look like a Mission Control
    /// transition.
    private static func isFullScreen(_ window: [String: Any]) -> Bool {
        guard let dictionary = window[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary) else { return false }
        return NSScreen.screens.contains { screen in
            bounds.width >= screen.frame.width * 0.9 && bounds.height >= screen.frame.height * 0.9
        }
    }
}
