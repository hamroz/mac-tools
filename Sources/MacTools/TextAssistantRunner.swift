import Foundation
import MacToolsCore

enum TextAssistantStatus: Equatable {
    case working(String)
    case success(String)
    case failure(String)
}

/// Where a run reports progress; the HUD in the app, a recorder in tests.
@MainActor
protocol TextAssistantFeedback: AnyObject {
    func show(_ status: TextAssistantStatus)
    func hide()
}

/// Runs one transformation at a time: capture → model → replace. A new run
/// cancels the one in flight, after that one has put the clipboard back.
@MainActor
final class TextAssistantRunner: ObservableObject {
    @Published private(set) var isRunning = false
    /// Kept in memory only, so a result that couldn't be pasted is recoverable.
    @Published private(set) var lastResult: String?

    private let settings: TextAssistantSettings
    private let bridge: TextSelectionBridge
    private let feedback: TextAssistantFeedback
    private let makeProvider: @MainActor (TextAssistantSettings) -> TextProvider
    private var current: Task<Void, Never>?
    private var generation = 0

    /// Called when a run stops for missing Accessibility access.
    var onAccessibilityMissing: (() -> Void)?

    init(
        settings: TextAssistantSettings,
        bridge: TextSelectionBridge,
        feedback: TextAssistantFeedback,
        makeProvider: @escaping @MainActor (TextAssistantSettings) -> TextProvider
    ) {
        self.settings = settings
        self.bridge = bridge
        self.feedback = feedback
        self.makeProvider = makeProvider
    }

    func improveSelection() {
        let previous = current
        previous?.cancel()
        generation += 1
        let run = generation
        current = Task { [weak self] in
            // Let the previous run finish its clipboard work before reading the selection.
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            await self.perform(run)
        }
    }

    func cancel() {
        current?.cancel()
    }

    /// Waits for the run in flight, for tests and orderly shutdown.
    func waitUntilIdle() async {
        await current?.value
    }

    private func perform(_ run: Int) async {
        isRunning = true
        defer { if run == generation { isRunning = false } }
        feedback.show(.working("Improving…"))

        var result: String?
        do {
            let selection = try await bridge.capture()
            let length = selection.text.count
            guard length <= settings.maxLength else {
                throw TextAssistantError.textTooLong(limit: settings.maxLength, actual: length)
            }
            let request = TextAssistantPrompt.improveRequest(text: selection.text, model: settings.effectiveModel)
            let raw = try await makeProvider(settings).complete(request)
            try Task.checkCancellation()
            let output = TextAssistantOutput.reconcile(raw, original: selection.text)
            result = output
            lastResult = output
            guard output != selection.text else {
                feedback.show(.success("Already looks good"))
                return
            }
            try await bridge.replace(selection, with: output)
            feedback.show(.success("Done"))
        } catch is CancellationError {
            // A newer run owns the HUD now.
            if run == generation { feedback.hide() }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if let result {
                bridge.leaveOnClipboard(result)
                feedback.show(.failure("\(message) The result is on the clipboard; press ⌘V to paste it."))
            } else {
                feedback.show(.failure(message))
            }
            if (error as? TextAssistantError) == .accessibilityNotTrusted { onAccessibilityMissing?() }
        }
    }
}
