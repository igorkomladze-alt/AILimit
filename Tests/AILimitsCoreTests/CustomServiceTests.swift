import XCTest
@testable import AILimitsCore

final class CustomServiceTests: XCTestCase {
    func definition(_ metric: CustomMetric) -> CustomServiceDefinition { .init(name: "Test", endpoint: URL(string: "https://example.com/balance")!, metrics: [metric]) }
    func testExactNumericAndStringDecimals() throws {
        for literal in ["1234567890.123456789012345678", "\"1234567890.123456789012345678\""] {
            let config = definition(.init(name: "Balance", valuePath: "items.0.amount", kind: .balance, currencyPath: "items.0.currency"))
            let snapshot = try CustomJSONParser.parse(Data("{\"items\":[{\"amount\":\(literal),\"currency\":\"CNY\"}]}".utf8), definition: config)
            XCTAssertEqual(snapshot.metrics[0].value, Decimal(string: "1234567890.123456789012345678"))
            XCTAssertEqual(snapshot.metrics[0].currency, "CNY")
        }
    }
    func testMissingPathAndBooleanAreRejectedWithoutResponseLeak() {
        let config = definition(.init(name: "Balance", valuePath: "balance", kind: .balance))
        for body in ["{\"private\":\"SECRET\"}", "{\"balance\":true}", "{\"balance\":\"NaN\"}", "{\"balance\":\"1oops\"}"] {
            XCTAssertThrowsError(try CustomJSONParser.parse(Data(body.utf8), definition: config)) { error in XCTAssertFalse(error.localizedDescription.contains("SECRET")) }
        }
    }
    func testNegativeBalanceAllowedButPercentOutOfRangeRejected() throws {
        XCTAssertEqual(try CustomJSONParser.parse(Data("{\"v\":-1.25}".utf8), definition: definition(.init(name: "Balance", valuePath: "v", kind: .balance))).metrics[0].value, Decimal(string: "-1.25"))
        for value in [-1,101] { XCTAssertThrowsError(try CustomJSONParser.parse(Data("{\"v\":\(value)}".utf8), definition: definition(.init(name: "Percent", valuePath: "v", kind: .remainingPercent)))) }
    }
    func testEndpointAndPathsValidation() {
        for url in ["http://example.com", "https://user:pass@example.com", "https://example.com?key=secret", "https://example.com#secret"] {
            var config = definition(.init(name: "x", valuePath: "x", kind: .balance)); config.endpoint = URL(string:url)!
            XCTAssertThrowsError(try config.validate())
        }
        XCTAssertThrowsError(try definition(.init(name: "x", valuePath: "a..b", kind: .balance)).validate())
    }
    func testResetEpochAndISO() throws {
        let config = definition(.init(name: "x", valuePath: "v", kind: .remainingCounts, totalPath: "total", resetPath: "reset"))
        for reset in ["1704067200", "\"2024-01-01T00:00:00Z\"", "\"2024-01-01T00:00:00.000Z\""] {
            let result = try CustomJSONParser.parse(Data("{\"v\":2,\"total\":10,\"reset\":\(reset)}".utf8), definition: config)
            XCTAssertEqual(result.metrics[0].resetAt, Date(timeIntervalSince1970: 1704067200))
        }
    }
    func testCurrencyMissingNeverDefaultsWhenPathSpecified() {
        XCTAssertThrowsError(try CustomJSONParser.parse(Data("{\"v\":2}".utf8), definition: definition(.init(name: "x", valuePath: "v", kind: .balance, currencyPath: "currency"))))
    }
    func testCountRequiresPositiveTotalAndRejectsOverage() throws {
        for kind in [CustomMetricKind.usedCounts, .remainingCounts] {
            XCTAssertThrowsError(try definition(.init(name: "Count", valuePath: "value", kind: kind)).validate())
            let config = definition(.init(name: "Count", valuePath: "value", kind: kind, totalPath: "total"))
            for body in ["{\"value\":1,\"total\":0}", "{\"value\":11,\"total\":10}", "{\"value\":-1,\"total\":10}", "{\"value\":1}"] {
                XCTAssertThrowsError(try CustomJSONParser.parse(Data(body.utf8), definition: config))
            }
            let valid = try CustomJSONParser.parse(Data("{\"value\":10,\"total\":10}".utf8), definition: config)
            XCTAssertEqual(valid.metrics[0].value, 10)
        }
    }

    func testSwitchFromCountsToPercentIgnoresPreviousTotalPath() throws {
        var metric = CustomMetric(name: "Usage", valuePath: "value", kind: .usedCounts, totalPath: "old.total")
        metric.kind = .usedPercent
        let snapshot = try CustomJSONParser.parse(Data("{\"value\":25}".utf8), definition: definition(metric))
        XCTAssertEqual(snapshot.metrics[0].value, 25)
        XCTAssertNil(snapshot.metrics[0].total)
        metric.totalPath = "old..invalid"
        XCTAssertNoThrow(try definition(metric).validate())
    }
    func testSwitchFromBalanceToPercentIgnoresPreviousCurrency() throws {
        var metric = CustomMetric(name: "Usage", valuePath: "value", kind: .balance, currency: "CNY", currencyPath: "old.currency")
        metric.kind = .remainingPercent
        let snapshot = try CustomJSONParser.parse(Data("{\"value\":75}".utf8), definition: definition(metric))
        XCTAssertEqual(snapshot.metrics[0].value, 75)
        XCTAssertNil(snapshot.metrics[0].currency)
        metric.currencyPath = "old..invalid"
        metric.currency = "invalid"
        XCTAssertNoThrow(try definition(metric).validate())
    }

}
