import XCTest
@testable import AILimitsCore

/// Задача 1 плана: контракты домена. Тест из плана (шаг 2) + граничные случаи.
final class DomainTests: XCTestCase {
    func testMissingIsNotZeroAndDefaultsAreApproved() {
        XCTAssertNil(QuotaValue.unknown.percent)
        XCTAssertNil(QuotaValue.unlimited.percent)
        XCTAssertEqual(QuotaValue.remainingPercent(0).percent, 0)
        XCTAssertNil(QuotaValue.remainingPercent(101).percent)
        XCTAssertNil(QuotaValue.counts(remaining: 1, total: 0, unit: "requests").percent)
        XCTAssertEqual(QuotaValue.counts(remaining: 25, total: 100, unit: "requests").percent, 25)
        XCTAssertEqual(AppSettings.defaults.openRouterThresholdUSD, Decimal(3))
        XCTAssertEqual(AppSettings.defaults.refreshSeconds, 300)
        XCTAssertEqual(AppSettings.defaults.maxConcurrent, 3)
        XCTAssertFalse(AppSettings.defaults.launchAtLogin)
    }

    /// План §1: неизвестное значение, ноль и безлимит — разные состояния.
    func testUnknownZeroUnlimitedAreDistinct() {
        XCTAssertNotEqual(QuotaValue.unknown, QuotaValue.remainingPercent(0))
        XCTAssertNotEqual(QuotaValue.unlimited, QuotaValue.remainingPercent(0))
        XCTAssertNotEqual(QuotaValue.unknown, QuotaValue.unlimited)
    }

    /// Дробный процент сохраняет точность (Decimal, не Double).
    func testFractionalPercentKeepsDecimalPrecision() {
        let value = QuotaValue.counts(remaining: 1, total: 3, unit: "requests")
        let percent = try? XCTUnwrap(value.percent)
        // 1/3*100 с внутренней точностью Decimal (36 значащих цифр мантиссы).
        XCTAssertEqual(percent, Decimal(string: "33.333333333333333333333333333333333333")!)
    }

    /// Отрицательный и NaN-подобный ввод отклоняется.
    func testInvalidCountsYieldNil() {
        XCTAssertNil(QuotaValue.counts(remaining: -1, total: 100, unit: "requests").percent)
        XCTAssertNil(QuotaValue.counts(remaining: 150, total: 100, unit: "requests").percent)
    }

    /// ConnectionID: поколение подключения стабильно идентифицируется.
    func testConnectionIDIdentity() {
        let generation = UUID()
        let a = ConnectionID(provider: .openrouter, generation: generation)
        let b = ConnectionID(provider: .openrouter, generation: generation)
        let c = ConnectionID(provider: .openrouter, generation: UUID())
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}
