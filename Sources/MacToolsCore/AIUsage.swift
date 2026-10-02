import Foundation

/// One rate-limit window, such as Claude's 5-hour session or a weekly limit.
public struct UsageWindow: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    /// 0–100, as reported by the service.
    public let usedPercent: Double
    public let resetsAt: Date?

    public init(id: String, title: String, usedPercent: Double, resetsAt: Date?) {
        self.id = id
        self.title = title
        self.usedPercent = min(max(usedPercent, 0), 100)
        self.resetsAt = resetsAt
    }

    public var remainingPercent: Double { 100 - usedPercent }

    /// A window read from an older record may already have reset.
    public func hasReset(at now: Date) -> Bool {
        resetsAt.map { $0 <= now } ?? false
    }

    /// Names a window by its length the way both services present them.
    public static func title(forWindowMinutes minutes: Int) -> String {
        switch minutes {
        case 0: "Usage"
        case 10_080: "Weekly limit"
        case 1_440: "Daily limit"
        case let value where value % 1_440 == 0: "\(value / 1_440)-day limit"
        case let value where value % 60 == 0: "\(value / 60)-hour limit"
        default: "\(minutes)-minute limit"
        }
    }
}

public struct UsageSnapshot: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        /// Fetched from the service just now.
        case live
        /// Read from the service's own local log, recorded at the given time.
        case localLog(recordedAt: Date?)
    }

    public var plan: String?
    public var windows: [UsageWindow]
    /// Extra lines such as prepaid credits or pay-as-you-go spending.
    public var details: [String]
    public var source: Source
    public var fetchedAt: Date

    public init(plan: String? = nil, windows: [UsageWindow], details: [String] = [], source: Source = .live, fetchedAt: Date = Date()) {
        self.plan = plan
        self.windows = windows
        self.details = details
        self.source = source
        self.fetchedAt = fetchedAt
    }

    /// The window closest to its limit, ignoring windows that have already reset.
    public func tightestWindow(at now: Date = Date()) -> UsageWindow? {
        windows.filter { !$0.hasReset(at: now) }.max { $0.usedPercent < $1.usedPercent }
    }
}

public enum UsageParseError: Error, Equatable {
    case unexpectedFormat
}

// MARK: - Claude

public enum ClaudeUsageParser {
    /// Parses the Claude Code OAuth usage response (`/api/oauth/usage`).
    public static func parse(_ data: Data, plan: String? = nil, now: Date = Date()) throws -> UsageSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageParseError.unexpectedFormat
        }
        let known: [(key: String, title: String)] = [
            ("five_hour", "5-hour session"),
            ("seven_day", "Weekly · all models"),
            ("seven_day_opus", "Weekly · Opus"),
            ("seven_day_sonnet", "Weekly · Sonnet"),
        ]
        let windows = known.compactMap { entry -> UsageWindow? in
            guard let window = root[entry.key] as? [String: Any],
                  let utilization = number(window["utilization"]) else { return nil }
            return UsageWindow(id: entry.key, title: entry.title, usedPercent: utilization,
                               resetsAt: (window["resets_at"] as? String).flatMap(isoDate))
        }
        guard !windows.isEmpty else { throw UsageParseError.unexpectedFormat }

        var details: [String] = []
        if let extra = root["extra_usage"] as? [String: Any], extra["is_enabled"] as? Bool == true,
           let used = number(extra["used_credits"]) {
            if let limit = number(extra["monthly_limit"]), limit > 0 {
                details.append("Extra usage: \(dollars(used)) of \(dollars(limit)) this month")
            } else {
                details.append("Extra usage: \(dollars(used)) this month")
            }
        }
        return UsageSnapshot(plan: plan, windows: windows, details: details, source: .live, fetchedAt: now)
    }

    /// Reads the plan name from Claude Code's stored credentials JSON without exposing the tokens.
    public static func credentials(from data: Data) -> (accessToken: String, plan: String?, expiresAt: Date?)? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        let plan = (oauth["subscriptionType"] as? String).map(planName)
        let expiresAt = number(oauth["expiresAt"]).map { Date(timeIntervalSince1970: $0 / 1000) }
        return (token, plan, expiresAt)
    }

    static func planName(_ raw: String) -> String {
        switch raw.lowercased() {
        case "max": "Max"
        case "pro": "Pro"
        case "team": "Team"
        case "enterprise": "Enterprise"
        default: raw.capitalized
        }
    }

    /// Anthropic reports extra-usage amounts in cents.
    private static func dollars(_ cents: Double) -> String {
        (cents / 100).formatted(.currency(code: "USD"))
    }
}

// MARK: - Codex

public enum CodexUsageParser {
    /// Parses the ChatGPT backend usage response Codex uses for `/status`.
    public static func parse(_ data: Data, now: Date = Date()) throws -> UsageSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageParseError.unexpectedFormat
        }
        let limits = root["rate_limit"] as? [String: Any]
        let windows = [("primary", limits?["primary_window"]), ("secondary", limits?["secondary_window"])]
            .compactMap { id, value -> UsageWindow? in
                guard let window = value as? [String: Any], let used = number(window["used_percent"]) else { return nil }
                let seconds = Int(number(window["limit_window_seconds"]) ?? 0)
                let resetsAt = number(window["reset_at"]).map { Date(timeIntervalSince1970: $0) }
                    ?? number(window["reset_after_seconds"]).map { now.addingTimeInterval($0) }
                return UsageWindow(id: id, title: UsageWindow.title(forWindowMinutes: seconds / 60),
                                   usedPercent: used, resetsAt: resetsAt)
            }
        guard limits != nil else { throw UsageParseError.unexpectedFormat }
        return UsageSnapshot(
            plan: (root["plan_type"] as? String).map(planName),
            windows: sorted(windows),
            details: creditDetails(root["credits"]),
            source: .live,
            fetchedAt: now
        )
    }

    /// Finds the most recent `rate_limits` record in Codex session log lines (JSONL).
    public static func latestLogSnapshot(lines: some Sequence<Substring>, now: Date = Date()) -> UsageSnapshot? {
        var latest: (date: Date?, limits: [String: Any])?
        for line in lines where line.contains("\"rate_limits\"") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let payload = object["payload"] as? [String: Any],
                  let limits = payload["rate_limits"] as? [String: Any] else { continue }
            let date = (object["timestamp"] as? String).flatMap(isoDate)
            if latest == nil || (date ?? .distantPast) >= (latest?.date ?? .distantPast) {
                latest = (date, limits)
            }
        }
        guard let latest else { return nil }
        let windows = [("primary", latest.limits["primary"]), ("secondary", latest.limits["secondary"])]
            .compactMap { id, value -> UsageWindow? in
                guard let window = value as? [String: Any], let used = number(window["used_percent"]) else { return nil }
                let minutes = Int(number(window["window_minutes"]) ?? 0)
                return UsageWindow(id: id, title: UsageWindow.title(forWindowMinutes: minutes), usedPercent: used,
                                   resetsAt: number(window["resets_at"]).map { Date(timeIntervalSince1970: $0) })
            }
        guard !windows.isEmpty else { return nil }
        return UsageSnapshot(
            plan: (latest.limits["plan_type"] as? String).map(planName),
            windows: sorted(windows),
            details: creditDetails(latest.limits["credits"]),
            source: .localLog(recordedAt: latest.date),
            fetchedAt: now
        )
    }

    /// Reads the access token and account from Codex's `auth.json`.
    public static func credentials(from data: Data) -> (accessToken: String, accountID: String?)? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, !token.isEmpty else { return nil }
        return (token, tokens["account_id"] as? String)
    }

    static func planName(_ raw: String) -> String {
        switch raw.lowercased() {
        case "plus": "Plus"
        case "pro": "Pro"
        case "team": "Team"
        case "business": "Business"
        case "enterprise": "Enterprise"
        case "edu": "Edu"
        case "free": "Free"
        default: raw.capitalized
        }
    }

    /// Shorter windows first, so a 5-hour limit appears above the weekly one.
    private static func sorted(_ windows: [UsageWindow]) -> [UsageWindow] {
        windows.sorted { order($0.title) < order($1.title) }
    }

    private static func order(_ title: String) -> Int {
        if title.contains("hour") || title.contains("minute") { return 0 }
        if title.contains("Daily") { return 1 }
        return 2
    }

    private static func creditDetails(_ value: Any?) -> [String] {
        guard let credits = value as? [String: Any] else { return [] }
        if credits["unlimited"] as? Bool == true { return ["Credits: unlimited"] }
        guard credits["has_credits"] as? Bool == true else { return [] }
        let balance = (credits["balance"] as? String) ?? number(credits["balance"]).map { String($0) }
        return balance.map { ["Credits balance: \($0)"] } ?? []
    }
}

// MARK: - Helpers

private func number(_ value: Any?) -> Double? {
    switch value {
    case let value as NSNumber: value.doubleValue
    case let value as String: Double(value)
    default: nil
    }
}

/// Accepts ISO 8601 timestamps with or without fractional seconds of any precision.
private func isoDate(_ string: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    if let date = formatter.date(from: string) { return date }
    // Drop fractional seconds (e.g. microseconds), which the formatter rejects beyond milliseconds.
    let trimmed = string.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
    return formatter.date(from: trimmed)
}
