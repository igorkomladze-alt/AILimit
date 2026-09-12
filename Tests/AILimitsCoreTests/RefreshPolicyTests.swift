import XCTest
@testable import AILimitsCore

/// Task 6, шаг 1: политика повторов — Retry-After не обходится.
final class RefreshPolicyTests: XCTestCase {
    let t = Date(timeIntervalSince1970: 1_800_000_000)

    func testBackoffSecondsSequence() {
        XCTAssertEqual((1...4).map { RefreshPolicy.backoffSeconds(failures: $0) },
                       [600, 1200, 1800, 1800])
        // Успех обнуляет счётчик — ноль неудач = штатный интервал.
        XCTAssertEqual(RefreshPolicy.backoffSeconds(failures: 0), 300)
    }

    func testRetryAfterCannotBeBypassed() {
        // Retry-After (2400 c) дальше, чем backoff (600 c): берётся максимум.
        XCTAssertEqual(
            RefreshPolicy.earliestRetry(failureAt: t, failures: 1, retryAfter: t.addingTimeInterval(2400)),
            t.addingTimeInterval(2400))
        // Backoff дальше Retry-After: берётся backoff.
        XCTAssertEqual(
            RefreshPolicy.earliestRetry(failureAt: t, failures: 1, retryAfter: t.addingTimeInterval(60)),
            t.addingTimeInterval(600))
        // Retry-After отсутствует: чистый backoff.
        XCTAssertEqual(
            RefreshPolicy.earliestRetry(failureAt: t, failures: 2, retryAfter: nil),
            t.addingTimeInterval(1200))
    }

    /// canStart: не в полёте И время наступило.
    func testCanStart() {
        XCTAssertFalse(RefreshPolicy.canStart(now: t, nextEligibleAt: t.addingTimeInterval(1), inFlight: false))
        XCTAssertFalse(RefreshPolicy.canStart(now: t, nextEligibleAt: t, inFlight: true))
        XCTAssertTrue(RefreshPolicy.canStart(now: t, nextEligibleAt: t, inFlight: false))
    }

    /// Ручное обновление уважает in-flight и backoff (но не возраст свежего значения).
    func testManualUpdateRespectsDeadlines() {
        // Ручной запрос при in-flight — отклонён (нет дублирования).
        XCTAssertFalse(RefreshPolicy.canStart(now: t, nextEligibleAt: t, inFlight: true))
        // Ручной запрос при backoff — отклонён (план: manual НЕ обходит Retry-After).
        XCTAssertFalse(RefreshPolicy.canStart(now: t, nextEligibleAt: t.addingTimeInterval(1800), inFlight: false))
    }
}
