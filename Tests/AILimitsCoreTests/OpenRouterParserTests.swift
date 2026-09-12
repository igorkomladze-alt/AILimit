import XCTest
@testable import AILimitsCore

/// Task 4, шаг 1: точная десятичная разность, отсутствующее поле, отрицательный баланс.
final class OpenRouterParserTests: XCTestCase {
    func testExactBalanceAndMissingUsage() throws {
        let response = Data(#"{"data":{"total_credits":10,"total_usage":7.0001}}"#.utf8)
        XCTAssertEqual(try OpenRouterParser.balance(from: response), Decimal(string: "2.9999"))
        XCTAssertThrowsError(try OpenRouterParser.balance(from: Data(#"{"data":{"total_credits":10}}"#.utf8)))
        let negative = Data(#"{"data":{"total_credits":1,"total_usage":2}}"#.utf8)
        XCTAssertEqual(try OpenRouterParser.balance(from: negative), -1)
    }

    /// Decimal напрямую из JSON: 0.1 + 0.2 стиль ошибок Double недопустим.
    func testNoDoubleIntermediary() throws {
        let response = Data(#"{"data":{"total_credits":0.1,"total_usage":0.05}}"#.utf8)
        XCTAssertEqual(try OpenRouterParser.balance(from: response), Decimal(string: "0.05"))
    }

    /// Неверная схема: не JSON, не объект, null-поля → invalidData.
    func testMalformedSchemasThrow() {
        XCTAssertThrowsError(try OpenRouterParser.balance(from: Data("not json".utf8)))
        XCTAssertThrowsError(try OpenRouterParser.balance(from: Data(#"{"error":"unauthorized"}"#.utf8)))
        XCTAssertThrowsError(try OpenRouterParser.balance(from: Data(#"{"data":{"total_credits":null,"total_usage":0}}"#.utf8)))
        XCTAssertThrowsError(try OpenRouterParser.balance(from: Data(#"[]"#.utf8)))
    }
}
