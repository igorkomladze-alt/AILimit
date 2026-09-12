import XCTest
@testable import AILimitsCore

/// Task 9: Z.ai — coding и MCP квоты раздельны, percentage это расход.
final class ZaiParserTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testCodingAndMCPAreNotAveraged() throws {
        let json = Data(#"{"success":true,"code":200,"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":25,"usage":100,"currentValue":25,"remaining":75},{"type":"TIME_LIMIT","unit":5,"number":1,"percentage":80}]}}"#.utf8)
        let result = try ZaiParser.quotas(from: json, now: now)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.first { $0.scope == "coding" }?.value.percent, 75)
        XCTAssertEqual(result.first { $0.scope == "mcp" }?.value.percent, 20)
    }

    /// CREDIT_LIMIT — тоже coding-окно.
    func testCreditLimitIsCoding() throws {
        let json = Data(#"{"success":true,"code":200,"data":{"limits":[{"type":"CREDIT_LIMIT","unit":1,"number":7,"percentage":30}]}}"#.utf8)
        let result = try ZaiParser.quotas(from: json, now: now)
        XCTAssertEqual(result.first { $0.scope == "coding" }?.value.percent, 70)
        XCTAssertEqual(result.first { $0.windowSeconds == 604800 }?.value.percent, 70) // 7 дней
    }

    /// Только MCP: coding-квоты нет.
    func testOnlyMCP() throws {
        let json = Data(#"{"success":true,"code":200,"data":{"limits":[{"type":"TIME_LIMIT","unit":5,"number":1,"percentage":50}]}}"#.utf8)
        let result = try ZaiParser.quotas(from: json, now: now)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].scope, "mcp")
    }

    /// Пустой limits = нет данных, не 100% (не копировать upstream fallback).
    func testEmptyLimitsYieldNoQuotas() throws {
        let json = Data(#"{"success":true,"code":200,"data":{"limits":[]}}"#.utf8)
        let result = try ZaiParser.quotas(from: json, now: now)
        XCTAssertTrue(result.isEmpty)
    }

    /// Неизвестный тип не ломает валидную соседнюю строку.
    func testUnknownTypeKeepsValidNeighbor() throws {
        let json = Data(#"{"success":true,"code":200,"data":{"limits":[{"type":"WEIRD","unit":3,"number":1,"percentage":10},{"type":"TOKENS_LIMIT","unit":3,"number":1,"percentage":40}]}}"#.utf8)
        let result = try ZaiParser.quotas(from: json, now: now)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].scope, "coding")
    }

    /// percentage вне 0…100 → unknown.
    func testOutOfRangePercentageYieldsUnknown() throws {
        let json = Data(#"{"success":true,"code":200,"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":1,"percentage":150}]}}"#.utf8)
        let result = try ZaiParser.quotas(from: json, now: now)
        XCTAssertEqual(result.count, 1)
        XCTAssertNil(result[0].value.percent)
    }

    /// nextResetTime — epoch milliseconds, не seconds (чудовищно большая дата = секунды → unknown).
    func testResetTimeEpochMillis() throws {
        let json = Data(#"{"success":true,"code":200,"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":1,"percentage":10,"nextResetTime":1800000300000}]}}"#.utf8)
        let result = try ZaiParser.quotas(from: json, now: now)
        // 1_800_000_300_000 ms = 1_800_000_300 s → валидная дата
        XCTAssertEqual(result[0].resetsAt, Date(timeIntervalSince1970: 1_800_000_300))
    }

    /// Неверная схема → invalidData.
    func testMalformedSchemaThrows() {
        XCTAssertThrowsError(try ZaiParser.quotas(from: Data("not json".utf8), now: now))
        XCTAssertThrowsError(try ZaiParser.quotas(from: Data(#"{"success":false,"code":500}"#.utf8), now: now))
        XCTAssertThrowsError(try ZaiParser.quotas(from: Data(#"{"data":{"limits":[]}}"#.utf8), now: now))
    }
}
