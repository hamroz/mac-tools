import XCTest
@testable import MacToolsCore

final class AIUsageParserTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    func test_ClaudeResponseProducesSessionAndWeeklyWindows() throws {
        let json = """
        {"five_hour":{"utilization":42.0,"resets_at":"2026-09-28T23:00:00.123456+00:00"},
         "seven_day":{"utilization":17,"resets_at":"2026-10-02T08:00:00Z"},
         "seven_day_opus":null,
         "seven_day_sonnet":{"utilization":3.5,"resets_at":null},
         "extra_usage":{"is_enabled":true,"monthly_limit":5000,"used_credits":1234}}
        """
        let snapshot = try ClaudeUsageParser.parse(Data(json.utf8), plan: "Max", now: now)
        XCTAssertEqual(snapshot.plan, "Max")
        XCTAssertEqual(snapshot.windows.map(\.id), ["five_hour", "seven_day", "seven_day_sonnet"])
        XCTAssertEqual(snapshot.windows[0].title, "5-hour session")
        XCTAssertEqual(snapshot.windows[0].remainingPercent, 58)
        XCTAssertEqual(snapshot.windows[0].resetsAt, ISO8601DateFormatter().date(from: "2026-09-28T23:00:00Z"))
        XCTAssertEqual(snapshot.windows[1].resetsAt, ISO8601DateFormatter().date(from: "2026-10-02T08:00:00Z"))
        XCTAssertNil(snapshot.windows[2].resetsAt)
        let spent = (12.34).formatted(.currency(code: "USD")), limit = (50.0).formatted(.currency(code: "USD"))
        XCTAssertEqual(snapshot.details, ["Extra usage: \(spent) of \(limit) this month"])
        XCTAssertEqual(snapshot.source, .live)
    }

    func test_ClaudeResponseWithoutWindowsIsRejected() {
        XCTAssertThrowsError(try ClaudeUsageParser.parse(Data(#"{"error":{"message":"nope"}}"#.utf8)))
        XCTAssertThrowsError(try ClaudeUsageParser.parse(Data("[]".utf8)))
    }

    func test_ClaudeCredentialsExposePlanAndExpiry() throws {
        let json = #"{"claudeAiOauth":{"accessToken":"secret","refreshToken":"r","expiresAt":1790000000000,"subscriptionType":"max"}}"#
        let credentials = try XCTUnwrap(ClaudeUsageParser.credentials(from: Data(json.utf8)))
        XCTAssertEqual(credentials.accessToken, "secret")
        XCTAssertEqual(credentials.plan, "Max")
        XCTAssertEqual(credentials.expiresAt, now)
        XCTAssertNil(ClaudeUsageParser.credentials(from: Data(#"{"claudeAiOauth":{}}"#.utf8)))
    }

    func test_CodexResponseProducesWindowsOrderedByLength() throws {
        let json = """
        {"plan_type":"plus",
         "rate_limit":{"allowed":true,"limit_reached":false,
           "primary_window":{"used_percent":80,"limit_window_seconds":604800,"reset_after_seconds":100,"reset_at":1790100000},
           "secondary_window":{"used_percent":12,"limit_window_seconds":18000,"reset_after_seconds":600}},
         "credits":{"has_credits":true,"unlimited":false,"balance":"25"}}
        """
        let snapshot = try CodexUsageParser.parse(Data(json.utf8), now: now)
        XCTAssertEqual(snapshot.plan, "Plus")
        XCTAssertEqual(snapshot.windows.map(\.title), ["5-hour limit", "Weekly limit"])
        XCTAssertEqual(snapshot.windows[0].resetsAt, now.addingTimeInterval(600))
        XCTAssertEqual(snapshot.windows[1].resetsAt, Date(timeIntervalSince1970: 1_790_100_000))
        XCTAssertEqual(snapshot.details, ["Credits balance: 25"])
        XCTAssertEqual(snapshot.tightestWindow(at: now)?.usedPercent, 80)
    }

    func test_CodexResponseWithoutRateLimitIsRejected() {
        XCTAssertThrowsError(try CodexUsageParser.parse(Data(#"{"detail":"Unauthorized"}"#.utf8)))
    }

    func test_CodexLogPicksNewestRateLimitRecord() throws {
        let lines = """
        {"timestamp":"2026-09-28T10:00:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":1.0,"window_minutes":300,"resets_at":1789000000},"secondary":null}}}
        {"timestamp":"2026-09-28T12:00:00.000Z","type":"response_item","payload":{"type":"message"}}
        {"timestamp":"2026-09-28T11:00:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":3.0,"window_minutes":10080,"resets_at":1790100000},"secondary":{"used_percent":9.0,"window_minutes":300,"resets_at":1789999000},"credits":{"has_credits":false,"unlimited":false,"balance":"0"},"plan_type":"pro"}}}
        not json
        """
        let snapshot = try XCTUnwrap(CodexUsageParser.latestLogSnapshot(lines: lines.split(separator: "\n"), now: now))
        XCTAssertEqual(snapshot.plan, "Pro")
        XCTAssertEqual(snapshot.windows.map(\.title), ["5-hour limit", "Weekly limit"])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [9, 3])
        XCTAssertEqual(snapshot.source, .localLog(recordedAt: ISO8601DateFormatter().date(from: "2026-09-28T11:00:00Z")))
        XCTAssertTrue(snapshot.windows[0].hasReset(at: now), "A window whose reset time passed must be treated as reset")
        XCTAssertEqual(snapshot.tightestWindow(at: now)?.title, "Weekly limit")
        XCTAssertTrue(snapshot.details.isEmpty)
    }

    func test_CodexLogWithoutRateLimitsYieldsNothing() {
        XCTAssertNil(CodexUsageParser.latestLogSnapshot(lines: [#"{"payload":{"type":"message"}}"#[...]]))
    }

    func test_CodexCredentials() throws {
        let json = #"{"OPENAI_API_KEY":null,"tokens":{"id_token":"i","access_token":"a","refresh_token":"r","account_id":"acc"}}"#
        let credentials = try XCTUnwrap(CodexUsageParser.credentials(from: Data(json.utf8)))
        XCTAssertEqual(credentials.accessToken, "a")
        XCTAssertEqual(credentials.accountID, "acc")
        XCTAssertNil(CodexUsageParser.credentials(from: Data(#"{"OPENAI_API_KEY":"sk"}"#.utf8)))
    }

    func test_WindowTitlesFollowWindowLength() {
        XCTAssertEqual(UsageWindow.title(forWindowMinutes: 300), "5-hour limit")
        XCTAssertEqual(UsageWindow.title(forWindowMinutes: 10_080), "Weekly limit")
        XCTAssertEqual(UsageWindow.title(forWindowMinutes: 1_440), "Daily limit")
        XCTAssertEqual(UsageWindow.title(forWindowMinutes: 45), "45-minute limit")
        XCTAssertEqual(UsageWindow(id: "x", title: "x", usedPercent: 140, resetsAt: nil).remainingPercent, 0)
    }
}
