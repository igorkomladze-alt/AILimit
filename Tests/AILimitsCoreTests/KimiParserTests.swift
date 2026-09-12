import XCTest
@testable import AILimitsCore

/// Task 8, шаг 1: Kimi — основной счётчик и timed-окна остаются раздельными.
final class KimiParserTests: XCTestCase {
    func testMainAndTimedQuotaRemainSeparate() throws {
        let body = Data(#"{"usage":{"limit":"1000","used":"250","remaining":"750"},"limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"200","used":"150","remaining":"50"}}]}"#.utf8)
        let quotas = try KimiParser.quotas(from: body)
        XCTAssertEqual(quotas.count, 2)
        XCTAssertEqual(quotas.first { $0.id == "kimi.code.main" }?.value.percent, 75)
        XCTAssertEqual(quotas.first { $0.windowSeconds == 18000 }?.value.percent, 25)
    }

    /// Числовые поля могут быть JSON numbers (не только строками).
    func testNumericJSONValues() throws {
        let body = Data(#"{"usage":{"limit":1000,"used":100},"limits":[]}"#.utf8)
        let quotas = try KimiParser.quotas(from: body)
        XCTAssertEqual(quotas.first { $0.id == "kimi.code.main" }?.value.percent, 90)
    }

    /// remaining отсутствует → выводится как limit − used.
    func testMissingRemainingDerived() throws {
        let body = Data(#"{"usage":{"limit":"500","used":"100"},"limits":[]}"#.utf8)
        let quotas = try KimiParser.quotas(from: body)
        XCTAssertEqual(quotas.first { $0.id == "kimi.code.main" }?.value.percent, 80)
    }

    /// Строки, не являющиеся JSON-number ("100abc", "NaN"), → invalidData, не 0.
    func testMalformedNumberStringsRejected() {
        let body = Data(#"{"usage":{"limit":"100abc","used":"1"},"limits":[]}"#.utf8)
        XCTAssertThrowsError(try KimiParser.quotas(from: body))
        let nan = Data(#"{"usage":{"limit":"NaN","used":"1"},"limits":[]}"#.utf8)
        XCTAssertThrowsError(try KimiParser.quotas(from: nan))
    }

    /// resetTime опционален; ISO 8601 с fractional seconds (9 знаков).
    func testResetTimeWithFractionalSeconds() throws {
        let body = Data(#"{"usage":{"limit":"100","used":"10","resetTime":"2026-01-09T15:23:13.716839300Z"},"limits":[]}"#.utf8)
        let quotas = try KimiParser.quotas(from: body)
        XCTAssertEqual(quotas.count, 1)
        XCTAssertNotNil(quotas[0].resetsAt)
    }

    /// Нулевой denominator → unknown.
    func testZeroLimitYieldsUnknown() throws {
        let body = Data(#"{"usage":{"limit":"0","used":"0"},"limits":[]}"#.utf8)
        let quotas = try KimiParser.quotas(from: body)
        XCTAssertNil(quotas.first { $0.id == "kimi.code.main" }?.value.percent)
    }

    /// Неверная схема → invalidData.
    func testMalformedSchemaThrows() {
        XCTAssertThrowsError(try KimiParser.quotas(from: Data("not json".utf8)))
        XCTAssertThrowsError(try KimiParser.quotas(from: Data(#"{"error":"x"}"#.utf8)))
    }

    /// Несколько timed-окон не схлопываются; unit SECOND/HOUR/DAY конвертируются.
    func testMultipleWindows() throws {
        let window = #"{"window":{"duration":5,"timeUnit":"TIME_UNIT_HOUR"},"detail":{"limit":"10","used":"2"}}"#
        let body = Data(#"{"usage":{"limit":"100","used":"10"},"limits":[\#(window)]}"#.utf8)
        let quotas = try KimiParser.quotas(from: body)
        XCTAssertEqual(quotas.count, 2) // main + 1 окно
        XCTAssertEqual(quotas.first { $0.windowSeconds == 18000 }?.value.percent, 80)
    }
}
