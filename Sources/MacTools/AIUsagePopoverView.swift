import MacToolsCore
import SwiftUI

extension UsageServiceID {
    var tint: Color {
        switch self {
        case .claude: Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex: Color(red: 0.06, green: 0.64, blue: 0.50)
        }
    }
}

/// The menu bar popover: one card per service with its rate-limit windows.
struct AIUsagePopoverView: View {
    @ObservedObject var store: AIUsageStore
    @ObservedObject var settings: AIUsageSettings
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if store.activeServices.isEmpty {
                Text("No services are turned on. Choose them in AI Usage settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ForEach(store.activeServices) { service in
                    ServiceUsageCard(service: service, state: store.state(for: service))
                }
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text("AI Usage")
                    .font(.headline)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(updatedText(now: context.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if store.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 20, height: 20)
            } else {
                Button {
                    store.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh now")
                .accessibilityLabel("Refresh")
            }
            Button(action: openSettings) {
                Image(systemName: "gearshape")
            }
            .help("AI Usage settings")
            .accessibilityLabel("Settings")
        }
        .buttonStyle(.borderless)
        .imageScale(.large)
    }

    private func updatedText(now: Date) -> String {
        if store.isRefreshing && store.lastRefresh == nil { return "Checking…" }
        guard let last = store.lastRefresh else { return "Not checked yet" }
        if now.timeIntervalSince(last) < 45 { return "Updated just now" }
        return "Updated \(last.formatted(.relative(presentation: .named)))"
    }
}

private struct ServiceUsageCard: View {
    let service: UsageServiceID
    let state: UsageServiceState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ToolIcon(symbolName: service.symbolName, tint: service.tint, size: 22)
                Text(service.name)
                    .font(.subheadline.weight(.semibold))
                if let plan = state.snapshot?.plan {
                    Text(plan)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(service.tint.opacity(0.18), in: Capsule())
                        .foregroundStyle(service.tint)
                }
                Spacer()
                if state.isLoading {
                    ProgressView().controlSize(.small)
                }
            }

            if let snapshot = state.snapshot {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(snapshot.windows) { window in
                            UsageWindowRow(window: window, now: context.date)
                        }
                    }
                }
                ForEach(snapshot.details, id: \.self) { detail in
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if case .localLog(let recordedAt) = snapshot.source {
                    Label(logNote(recordedAt), systemImage: "clock.arrow.circlepath")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if state.errorMessage == nil {
                Text("Checking…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = state.errorMessage {
                Label(state.snapshot == nil ? error : "Couldn’t update. \(error)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func logNote(_ recordedAt: Date?) -> String {
        guard let recordedAt else { return "From your last Codex session" }
        return "From your last Codex session, \(recordedAt.formatted(.relative(presentation: .named)))"
    }
}

private struct UsageWindowRow: View {
    let window: UsageWindow
    let now: Date

    var body: some View {
        let reset = window.hasReset(at: now)
        let remaining = reset ? 100 : window.remainingPercent
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.title)
                    .font(.callout)
                Spacer()
                Text("\(Int(remaining.rounded()))% left")
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(color(remaining))
            }
            UsageBar(fraction: remaining / 100, color: color(remaining))
            Text(resetText(reset: reset))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func color(_ remaining: Double) -> Color {
        switch remaining {
        case ..<10: .red
        case ..<30: .orange
        default: .green
        }
    }

    private func resetText(reset: Bool) -> String {
        if reset { return "Reset since then" }
        guard let resetsAt = window.resetsAt else { return "\(Int(window.usedPercent.rounded()))% used" }
        let used = "\(Int(window.usedPercent.rounded()))% used"
        let seconds = resetsAt.timeIntervalSince(now)
        if seconds < 24 * 3600 {
            return "\(used) · resets in \(Self.duration(seconds))"
        }
        return "\(used) · resets \(resetsAt.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded(.up)))
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }
}

private struct UsageBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(color.gradient)
                    .frame(width: max(fraction > 0 ? 6 : 0, proxy.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 6)
        .animation(.smooth, value: fraction)
    }
}
