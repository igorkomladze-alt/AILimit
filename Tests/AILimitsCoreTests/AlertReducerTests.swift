import XCTest
@testable import AILimitsCore

/// Task 7, шаг 1: эпизод OpenRouter переживает перезапуск (Codable round-trip).
final class AlertReducerTests: XCTestCase {
    private func d(_ string: String) -> Decimal {
        Decimal(string: string, locale: Locale(identifier: "en_US_POSIX"))!
    }

    func testThreeDollarEpisodeSurvivesRestart() throws {
        var state = BalanceEpisode()
        func feed(_ amount: String, fresh: Bool = true) -> BalanceAlert? {
            BalanceAlertReducer.observe(balance: d(amount), validFresh: fresh, state: &state)
        }
        XCTAssertNil(feed("3.00"))
        XCTAssertEqual(feed("2.99"), .lowBalance)
        XCTAssertNil(feed("2.80"))
        state = try JSONDecoder().decode(BalanceEpisode.self, from: JSONEncoder().encode(state))
        XCTAssertNil(feed("2.50"))
        XCTAssertNil(feed("3.50", fresh: false))
        XCTAssertNil(feed("2.80"))
        XCTAssertNil(feed("3.00"))
        XCTAssertEqual(feed("2.9999"), .lowBalance)
    }

    func testInitialLowAndPartialTopUp() {
        var state = BalanceEpisode()
        XCTAssertEqual(BalanceAlertReducer.observe(balance: 2, validFresh: true, state: &state), .lowBalance)
        XCTAssertNil(BalanceAlertReducer.observe(balance: d("2.8"), validFresh: true, state: &state))
        XCTAssertNil(BalanceAlertReducer.observe(balance: -1, validFresh: true, state: &state))
    }

    /// Кастомный порог: параметризованный (Decimal), default 3.
    func testCustomThreshold() {
        var state = BalanceEpisode()
        XCTAssertEqual(BalanceAlertReducer.observe(
            balance: d("9.99"), validFresh: true, threshold: 10, state: &state), .lowBalance)
        // Ровно порог — не ниже.
        var state2 = BalanceEpisode()
        XCTAssertNil(BalanceAlertReducer.observe(
            balance: 10, validFresh: true, threshold: 10, state: &state2))
    }

    // MARK: - Квотные эпизоды (шаг 4)

    func test25To19To4TwoEvents() {
        var state = QuotaEpisode()
        XCTAssertNil(QuotaAlertReducer.observe(remainingPercent: 25, state: &state))
        XCTAssertEqual(QuotaAlertReducer.observe(remainingPercent: 19, state: &state), .threshold(20))
        XCTAssertEqual(QuotaAlertReducer.observe(remainingPercent: 4, state: &state), .threshold(5))
    }

    /// 25 → 4: оба порога помечены, одно критичное событие.
    func test25To4SingleCriticalEvent() {
        var state = QuotaEpisode()
        XCTAssertNil(QuotaAlertReducer.observe(remainingPercent: 25, state: &state))
        XCTAssertEqual(QuotaAlertReducer.observe(remainingPercent: 4, state: &state), .threshold(5))
        XCTAssertTrue(state.sentThresholds.contains(20))
        XCTAssertTrue(state.sentThresholds.contains(5))
    }

    /// 4 → 10 перевзводит порог 5; повтор 9% даёт новое событие порога 5.
    func testRearmBetweenThresholds() {
        var state = QuotaEpisode()
        XCTAssertNil(QuotaAlertReducer.observe(remainingPercent: 25, state: &state))
        XCTAssertEqual(QuotaAlertReducer.observe(remainingPercent: 8, state: &state), .threshold(20))
        // Восстановление до 10% (>5): порог 5 перевзводится, 20 остаётся обработанным.
        XCTAssertNil(QuotaAlertReducer.observe(remainingPercent: 10, state: &state))
        XCTAssertFalse(state.sentThresholds.contains(5))
        XCTAssertTrue(state.sentThresholds.contains(20))
        // Повторное падение ниже 5 — новое событие 5.
        XCTAssertEqual(QuotaAlertReducer.observe(remainingPercent: 4, state: &state), .threshold(5))
    }

    /// Recovery: только после фактического предупреждения и остатка выше recovery-порога (20).
    func testRecoveryRequiresWarningAndAboveThreshold() {
        var state = QuotaEpisode()
        // 4% одним обновлением пересекает оба порога → критичный 5.
        XCTAssertEqual(QuotaAlertReducer.observe(remainingPercent: 4, state: &state), .threshold(5))
        // Восстановление до 26% (выше 20) — recovery.
        XCTAssertEqual(QuotaAlertReducer.observe(remainingPercent: 26, state: &state), .recovered)
        XCTAssertTrue(state.isRecovered)
        // Эпизод полностью сброшен: повторное падение даёт новое событие.
        XCTAssertEqual(QuotaAlertReducer.observe(remainingPercent: 15, state: &state), .threshold(20))
    }

    /// Без предшествующего предупреждения recovery невозможен.
    func testNoRecoveryWithoutWarning() {
        var state = QuotaEpisode()
        XCTAssertNil(QuotaAlertReducer.observe(remainingPercent: 30, state: &state))
        XCTAssertNil(QuotaAlertReducer.observe(remainingPercent: 26, state: &state))
    }

    /// Истёкший reset и новая дата reset сами по себе не создают событий.
    func testUnknownValuesDoNotMutate() {
        var state = QuotaEpisode()
        XCTAssertNil(QuotaAlertReducer.observe(remainingPercent: nil, state: &state))
        XCTAssertEqual(QuotaAlertReducer.observe(remainingPercent: 10, state: &state), .threshold(20))
        XCTAssertNil(QuotaAlertReducer.observe(remainingPercent: nil, state: &state))
        // состояние не изменилось
        XCTAssertEqual(state.sentThresholds, [20])
    }

    /// Граничное равенство: remaining == threshold засчитывается (план Task 7, шаг 4).
    func testBoundaryEqualityFires() {
        var state = QuotaEpisode()
        XCTAssertEqual(QuotaAlertReducer.observe(remainingPercent: 20, state: &state), .threshold(20))
    }

    /// Codable: эпизод переживает перезапуск.
    func testQuotaEpisodeCodable() throws {
        var state = QuotaEpisode()
        _ = QuotaAlertReducer.observe(remainingPercent: 15, state: &state)
        let restored = try JSONDecoder().decode(QuotaEpisode.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored, state)
    }

    /// Outbox: уникальные ID, переживают Codable-цикл.
    func testOutboxUniqueIDsAndCodable() throws {
        var outbox = NotificationOutbox()
        let event1 = AlertEvent(
            id: "conn1:quota:rule1:1", provider: .openrouter,
            title: "OpenRouter", body: "Баланс ниже $3")
        outbox.enqueue(event1)
        XCTAssertTrue(outbox.pendingIDs.contains("conn1:quota:rule1:1"))
        // Тот же ID не дублируется.
        outbox.enqueue(event1)
        XCTAssertEqual(outbox.pending.count, 1)
        // Codable round-trip.
        let restored = try JSONDecoder().decode(NotificationOutbox.self, from: JSONEncoder().encode(outbox))
        XCTAssertEqual(restored.pendingIDs, outbox.pendingIDs)
    }

    /// Красный тест из плана: состояние эпизода переживает перезапуск И после него
    /// «новое событие не возникает из того же сохранённого снимка».
    func testEpisodePersistsAcrossRestartInRepositoryLikeFlow() throws {
        // 1-я «сессия»: падение ниже $3 → событие.
        var state = BalanceEpisode()
        XCTAssertEqual(BalanceAlertReducer.observe(balance: d("2.50"), validFresh: true, state: &state), .lowBalance)
        let saved = try JSONEncoder().encode(state)
        // 2-я «сессия»: восстановили состояние из файла.
        var restored = try JSONDecoder().decode(BalanceEpisode.self, from: saved)
        XCTAssertNil(BalanceAlertReducer.observe(balance: d("2.60"), validFresh: true, state: &restored))
    }
}
