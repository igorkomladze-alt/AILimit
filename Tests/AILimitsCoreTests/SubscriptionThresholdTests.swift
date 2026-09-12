import XCTest
@testable import AILimitsCore

/// Процентные пороги подписок: 20% и 5% (спецификация §9).
final class SubscriptionThresholdTests: XCTestCase {
    let clock = MockClock()
    lazy var ledger = WarningLedger(clock: clock)

    private func p(_ value: Double) -> Double { value }

    func testPercent25To19To4EachThresholdFiresOnce() async throws {
        let at25 = try await ledger.evaluateQuota(provider: .claude, quotaID: "five_hour", remainingPercent: 25)
        XCTAssertTrue(at25.isEmpty)

        let at19 = try await ledger.evaluateQuota(provider: .claude, quotaID: "five_hour", remainingPercent: 19)
        XCTAssertEqual(at19, [20])

        let at4 = try await ledger.evaluateQuota(provider: .claude, quotaID: "five_hour", remainingPercent: 4)
        XCTAssertEqual(at4, [5])
    }

    func testPercent25To4SingleCriticalEvent() async throws {
        let at25 = try await ledger.evaluateQuota(provider: .codex, quotaID: "primary", remainingPercent: 25)
        XCTAssertTrue(at25.isEmpty)

        let at4 = try await ledger.evaluateQuota(provider: .codex, quotaID: "primary", remainingPercent: 4)
        XCTAssertEqual(at4, [5], "Оба порога пройдены: одно критичное событие")
    }

    func testRepeatedLowValuesNoRepeat() async throws {
        _ = try await ledger.evaluateQuota(provider: .kimi, quotaID: "weekly", remainingPercent: 3)
        let again = try await ledger.evaluateQuota(provider: .kimi, quotaID: "weekly", remainingPercent: 2)
        XCTAssertTrue(again.isEmpty)
    }

    func testRecoveryRequiresConfirmedObservationAbove20() async throws {
        _ = try await ledger.evaluateQuota(provider: .zai, quotaID: "coding_plan", remainingPercent: 10)

        // 15% — выше 5%, но ниже recovery-порога 20%: перевзводится только порог 5.
        let backTo15 = try await ledger.evaluateQuota(provider: .zai, quotaID: "coding_plan", remainingPercent: 15)
        XCTAssertTrue(backTo15.isEmpty, "Перевзвод порога 5% — не событие")

        // Снова 4% — порог 5% обрабатывается повторно.
        let backTo4 = try await ledger.evaluateQuota(provider: .zai, quotaID: "coding_plan", remainingPercent: 4)
        XCTAssertEqual(backTo4, [5])

        // Восстановление выше 20% — эпизод закрывается.
        let at30 = try await ledger.evaluateQuota(provider: .zai, quotaID: "coding_plan", remainingPercent: 30)
        XCTAssertTrue(at30.isEmpty)

        // Новое падение — новое событие.
        let dropAgain = try await ledger.evaluateQuota(provider: .zai, quotaID: "coding_plan", remainingPercent: 18)
        XCTAssertEqual(dropAgain, [20])
    }

    func testNilPercentDoesNotMutateState() async throws {
        _ = try await ledger.evaluateQuota(provider: .claude, quotaID: "five_hour", remainingPercent: 15)
        let atNil = try await ledger.evaluateQuota(provider: .claude, quotaID: "five_hour", remainingPercent: nil)
        XCTAssertTrue(atNil.isEmpty)
        let afterNil = try await ledger.evaluateQuota(provider: .claude, quotaID: "five_hour", remainingPercent: 12)
        XCTAssertTrue(afterNil.isEmpty)
    }

    func testSeparateQuotasIndependent() async throws {
        let weekly = try await ledger.evaluateQuota(provider: .claude, quotaID: "seven_day", remainingPercent: 8)
        let session = try await ledger.evaluateQuota(provider: .claude, quotaID: "five_hour", remainingPercent: 60)
        XCTAssertEqual(weekly, [20])
        XCTAssertTrue(session.isEmpty)
    }

    func testBoundaryEqualityFires() async throws {
        // Спецификация: порог срабатывает при remaining <= threshold (граничное равенство разрешено).
        let at20 = try await ledger.evaluateQuota(provider: .zai, quotaID: "main", remainingPercent: 20)
        XCTAssertEqual(at20, [20])
    }

    private func await_<T>(_ operation: () async throws -> T) async throws -> T {
        try await operation()
    }
}
