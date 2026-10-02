import AppKit
import Combine
import KeyboardShortcuts
import MacToolsCore
import SwiftUI

@MainActor
final class TextAssistantModule: NSObject, ToolModule {
    let descriptor = ToolDescriptor(
        id: "text-assistant",
        name: "Text Assistant",
        summary: "Improves the text you’ve selected in any app and puts the result right back in place.",
        symbolName: "wand.and.stars",
        tint: .teal
    )

    var openSettings: (() -> Void)?

    let settings: TextAssistantSettings
    let runner: TextAssistantRunner
    private let hud: TextAssistantHUD
    private var menuObservers: [AnyCancellable] = []

    init(settings: TextAssistantSettings = TextAssistantSettings()) {
        self.settings = settings
        let hud = TextAssistantHUD()
        self.hud = hud
        runner = TextAssistantRunner(
            settings: settings,
            bridge: TextSelectionBridge(pasteboard: SystemPasteboard(), environment: SystemSelectionEnvironment()),
            feedback: hud
        )
        super.init()
        runner.onAccessibilityMissing = { [weak self] in
            AccessibilityPermission.shared.request()
            self?.openSettings?()
        }
    }

    func start() {
        KeyboardShortcuts.onKeyDown(for: .textAssistantImprove) { [weak self] in
            self?.runner.improveSelection()
        }
    }

    func stop() {
        KeyboardShortcuts.removeHandler(for: .textAssistantImprove)
        runner.cancel()
        hud.hide()
    }

    func makeMenuItems() -> [NSMenuItem] {
        let improve = NSMenuItem(title: "Improve Selected Text", action: #selector(improveFromMenu), keyEquivalent: "")
        improve.target = self
        improve.setShortcut(for: .textAssistantImprove)

        let copyLast = NSMenuItem(title: "Copy Last Result", action: #selector(copyLastResult), keyEquivalent: "")
        copyLast.target = self
        menuObservers = [runner.$lastResult.sink { [weak copyLast] result in copyLast?.isHidden = result == nil }]
        return [improve, copyLast]
    }

    func makeSettingsView() -> AnyView {
        AnyView(TextAssistantSettingsView(settings: settings, permission: .shared))
    }

    /// The status menu never activates Mac Tools, so the selection stays in the frontmost app.
    @objc private func improveFromMenu() {
        // Let the menu finish closing before keystrokes go to the app.
        DispatchQueue.main.async { [weak self] in self?.runner.improveSelection() }
    }

    @objc private func copyLastResult() {
        guard let result = runner.lastResult else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result, forType: .string)
    }
}
