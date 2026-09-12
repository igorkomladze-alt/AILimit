import XCTest
@testable import AILimitsCore

/// Task 11, шаг 1: multi-bucket переопределяет legacy-представление.
final class CodexParserTests: XCTestCase {
    func testMultiBucketOverridesLegacyView() throws {
        let body = Data(#"{"rateLimits":{"limitId":"codex","primary":{"usedPercent":99,"windowDurationMins":300,"resetsAt":1800000300}},"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":1800000300},"secondary":null},"other":{"limitId":"other","primary":{"usedPercent":50,"windowDurationMins":60,"resetsAt":1800000600},"secondary":null}}}"#.utf8)
        let quotas = try CodexParser.quotas(fromResult: body)
        XCTAssertEqual(quotas.count, 2)
        XCTAssertEqual(quotas.first { $0.id == "codex.codex.primary" }?.value.percent, 75)
        XCTAssertEqual(quotas.first { $0.id == "codex.other.primary" }?.windowSeconds, 3600)
    }

    func testNamedGroupsAndPeriodsAreDistinctAndStable() throws {
        let data = Data(#"{"rateLimitsByLimitId":{"codex_bengalfox":{"limitName":"Special model","primary":{"usedPercent":0,"windowDurationMins":300},"secondary":{"usedPercent":0,"windowDurationMins":10080}},"base_model_inference":{"primary":{"usedPercent":100,"windowDurationMins":10080}},"codex":{"primary":{"usedPercent":11,"windowDurationMins":10080}}}}"#.utf8)
        let quotas = try CodexParser.quotas(fromResult: data)
        XCTAssertEqual(quotas.map(\.title), ["Codex · 7 дней", "base_model_inference · 7 дней", "Special model · 5 часов", "Special model · 7 дней"])
        XCTAssertEqual(quotas.first?.value.percent, 89)
        XCTAssertEqual(quotas.last?.scope, "codex_bengalfox")
        XCTAssertEqual(quotas.last?.id, "codex.codex_bengalfox.secondary")
    }

    func testMissingPeriodDoesNotInventFiveHours() throws {
        let data = Data(#"{"rateLimits":{"primary":{"usedPercent":0},"secondary":{"usedPercent":0}}}"#.utf8)
        let quotas = try CodexParser.quotas(fromResult: data)
        XCTAssertEqual(quotas.map(\.title), ["Codex · период 1", "Codex · период 2"])
    }

    /// Legacy-only ответ: rateLimits как единственный источник.
    func testLegacyFallback() throws {
        let body = Data(#"{"rateLimits":{"limitId":"codex","primary":{"usedPercent":31,"windowDurationMins":15,"resetsAt":1800000900}}}"#.utf8)
        let quotas = try CodexParser.quotas(fromResult: body)
        XCTAssertEqual(quotas.count, 1)
        XCTAssertEqual(quotas[0].id, "codex.codex.primary")
        XCTAssertEqual(quotas[0].value.percent, 69)
    }

    /// secondary bucket — отдельная квота.
    func testSecondaryBucketSeparate() throws {
        let body = Data(#"{"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":25,"windowDurationMins":300},"secondary":{"usedPercent":60,"windowDurationMins":10080}}}}"#.utf8)
        let quotas = try CodexParser.quotas(fromResult: body)
        XCTAssertEqual(quotas.count, 2)
        XCTAssertEqual(quotas.first { $0.id == "codex.codex.secondary" }?.value.percent, 40)
        XCTAssertEqual(quotas.first { $0.id == "codex.codex.secondary" }?.windowSeconds, 604800)
    }

    /// usedPercent вне 0…100 → unknown; невалидный ответ → invalidData.
    func testInvalidData() throws {
        let bad = Data(#"{"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":150,"windowDurationMins":60}}}}"#.utf8)
        let quotas = try CodexParser.quotas(fromResult: bad)
        XCTAssertNil(quotas[0].value.percent)
        XCTAssertThrowsError(try CodexParser.quotas(fromResult: Data("not json".utf8)))
    }
}
