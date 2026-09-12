import XCTest
@testable import AILimitsCore

/// Денежный порог OpenRouter: строго ниже $3 (спецификация §9, строки 1–7).
final class MoneyThresholdTests: XCTestCase {
    let clock = MockClock()
    lazy var ledger = WarningLedger(clock: clock)

    private func d(_ string: String) -> Decimal {
        Decimal(string: string, locale: Locale(identifier: "en_US_POSIX"))!
    }

    func testBalanceExactly3DollarsNoNotification() async throws {
        let fire = try await ledger.evaluateBalance(provider: .openrouter, balanceUSD: d("3.00"))
        XCTAssertFalse(fire)
    }

    func testBalance299After300SingleNotification() async throws {
        _ = try await ledger.evaluateBalance(provider: .openrouter, balanceUSD: d("3.00"))
        let fire = try await ledger.evaluateBalance(provider: .openrouter, balanceUSD: d("2.99"))
        XCTAssertTrue(fire)
    }

    func testFirstConnectionAlreadyLowSingleInitialNotification() async throws {
        let fire = try await ledger.evaluateBalance(provider: .openrouter, balanceUSD: d("2.50"))
        XCTAssertTrue(fire)
    }

    func testRepeatedLowValuesNoNewNotifications() async throws {
        _ = try await ledger.evaluateBalance(provider: .openrouter, balanceUSD: d("2.50"))
        let second = try await ledger.evaluateBalance(provider: .openrouter, balanceUSD: d("2.80"))
        let third = try await ledger.evaluateBalance(provider: .openrouter, balanceUSD: d("2.99"))
        XCTAssertFalse(second)
        XCTAssertFalse(third)
    }

    func testRecoveryThenDropAgainNewEpisode() async throws {
        _ = try await ledger.evaluateBalance(provider: .openrouter, balanceUSD: d("2.80"))
        // Ровно $3.00 — не ниже порога: эпизод закрывается.
        let atRecovery = try await ledger.evaluateBalance(provider: .openrouter, balanceUSD: d("3.00"))
        XCTAssertFalse(atRecovery)
        // Новое падение — новое событие.
        let dropAgain = try await ledger.evaluateBalance(provider: .openrouter, balanceUSD: d("2.99"))
        XCTAssertTrue(dropAgain)
    }

    func testTopupBelowThresholdDoesNotAllowRepeat() async throws {
        _ = try await ledger.evaluateBalance(provider: .openrouter, balanceUSD: d("2.00"))
        // Пополнение, но всё ещё ниже $3: эпизод не закрыт, повтора нет.
        let afterTopup = try await ledger.evaluateBalance(provider: .openrouter, balanceUSD: d("2.80"))
        XCTAssertFalse(afterTopup)
    }

    func testNilBalanceDoesNotChangeState() async throws {
        _ = try await ledger.evaluateBalance(provider: .openrouter, balanceUSD: d("2.50"))
        let onError = try await ledger.evaluateBalance(provider: .openrouter, balanceUSD: nil)
        XCTAssertFalse(onError)
        let afterError = try await ledger.evaluateBalance(provider: .openrouter, balanceUSD: d("2.40"))
        XCTAssertFalse(afterError)
    }

    func testSubCentPrecisionAndNegativeBalance() async throws {
        // 2.9999 < 3 — строго ниже; точность Decimal не теряется.
        let first = try await ledger.evaluateBalance(provider: .openrouter, balanceUSD: d("2.9999"))
        XCTAssertTrue(first)
        // Отрицательный баланс — не новый эпизод.
        let second = try await ledger.evaluateBalance(provider: .openrouter, balanceUSD: d("-0.50"))
        XCTAssertFalse(second)
    }

    // MARK: - Чистый редьюсер (Task 7 контракт)

    func testReducerExactThreeNoAlert() {
        var state = BalanceEpisode()
        let alert = BalanceAlertReducer.observe(balance: d("3.00"), validFresh: true, state: &state)
        XCTAssertNil(alert)
        XCTAssertFalse(state.isBelow)
    }

    func testReducerSubCentBelowAlerts() {
        var state = BalanceEpisode()
        let alert = BalanceAlertReducer.observe(balance: d("2.9999"), validFresh: true, state: &state)
        XCTAssertEqual(alert, .lowBalance)
        XCTAssertTrue(state.isBelow)
    }

    func testReducerNotFreshDoesNotMutateState() {
        var state = BalanceEpisode(isBelow: true)
        let alert = BalanceAlertReducer.observe(balance: d("5.00"), validFresh: false, state: &state)
        XCTAssertNil(alert)
        XCTAssertTrue(state.isBelow, "Не-свежие данные не закрывают эпизод")
    }

    func testReducerCustomThreshold() {
        var state = BalanceEpisode()
        let alert = BalanceAlertReducer.observe(balance: d("4.50"), validFresh: true, threshold: d("5"), state: &state)
        XCTAssertEqual(alert, .lowBalance)
    }

    // Вспомогательный await для actor-методов.
    private func await_<T>(_ operation: () async throws -> T) async throws -> T {
        try await operation()
    }
}
