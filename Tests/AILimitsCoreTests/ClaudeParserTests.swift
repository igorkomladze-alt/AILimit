import XCTest
@testable import AILimitsCore

/// Task 10, шаг 1: utilization — это РАСХОД, а не остаток.
final class ClaudeParserTests: XCTestCase {
    func testUtilizationMeansUsedNotRemaining() throws {
        let response = Data(#"{"five_hour":{"utilization":35,"resets_at":null},"seven_day":{"utilization":80,"resets_at":null},"seven_day_opus":null}"#.utf8)
        let quotas = try ClaudeParser.quotas(from: response)
        XCTAssertEqual(quotas.first { $0.id == "claude.five_hour" }?.value.percent, 65)
        XCTAssertEqual(quotas.first { $0.id == "claude.seven_day" }?.value.percent, 20)
        // null-окно не превращается в 100% и не порождает квоту.
        XCTAssertFalse(quotas.contains { $0.id == "claude.seven_day_opus" })
    }

    /// Наличие short-окна не обязательно: недельное остаётся доступным.
    func testWeeklyWithoutFiveHour() throws {
        let response = Data(#"{"five_hour":null,"seven_day":{"utilization":10,"resets_at":1800000300}}"#.utf8)
        let quotas = try ClaudeParser.quotas(from: response)
        XCTAssertEqual(quotas.count, 1)
        XCTAssertEqual(quotas[0].id, "claude.seven_day")
        XCTAssertEqual(quotas[0].value.percent, 90)
        XCTAssertEqual(quotas[0].resetsAt, Date(timeIntervalSince1970: 1_800_000_300))
    }

    /// utilization вне 0…100 → unknown.
    func testOutOfRangeUtilizationUnknown() throws {
        let response = Data(#"{"five_hour":{"utilization":140,"resets_at":null}}"#.utf8)
        let quotas = try ClaudeParser.quotas(from: response)
        XCTAssertEqual(quotas.count, 1)
        XCTAssertNil(quotas[0].value.percent)
    }

    /// extra_usage (деньги) не подменяет процент подписки.
    func testExtraUsageNotQuotaPercent() throws {
        let response = Data(#"{"five_hour":{"utilization":10,"resets_at":null},"extra_usage":{"utilization":99}}"#.utf8)
        let quotas = try ClaudeParser.quotas(from: response)
        XCTAssertFalse(quotas.contains { $0.id.contains("extra") })
        XCTAssertEqual(quotas.count, 1)
    }

    /// Неверная схема → invalidData.
    func testMalformedSchemaThrows() {
        XCTAssertThrowsError(try ClaudeParser.quotas(from: Data("not json".utf8)))
        XCTAssertThrowsError(try ClaudeParser.quotas(from: Data(#"{"error":"unauthorized"}"#.utf8)))
    }
}
