import XCTest
import Foundation
@testable import AILimitsCore

/// Свежесть и неизвестные значения (спецификация §6, §9; план Task 1/Task 5).
final class FreshnessAndUnknownValueTests: XCTestCase {
    private func connection(_ provider: ProviderID) -> ConnectionID {
        ConnectionID(provider: provider, generation: UUID())
    }

    /// План Task 5, шаг 1: кэш не омолаживается; сбой и истёкший reset делают данные несвежими.
    func testCacheDoesNotAcquireANewObservationTime() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(SnapshotPolicy.isFresh(fetchedAt: t, observedAt: nil,
            lastRefreshFailed: false, resetAt: nil, now: t.addingTimeInterval(600)))
        XCTAssertFalse(SnapshotPolicy.isFresh(fetchedAt: t, observedAt: nil,
            lastRefreshFailed: false, resetAt: nil, now: t.addingTimeInterval(601)))
        XCTAssertFalse(SnapshotPolicy.isFresh(fetchedAt: t, observedAt: nil,
            lastRefreshFailed: true, resetAt: nil, now: t))
        XCTAssertFalse(SnapshotPolicy.isFresh(fetchedAt: t, observedAt: nil,
            lastRefreshFailed: false, resetAt: t.addingTimeInterval(30),
            now: t.addingTimeInterval(31)))
    }

    /// observedAt (если реально возвращён провайдером) участвует в оценке свежести.
    func testObservedAtEarlierThanFetchedAtIsUsed() {
        let fetched = Date(timeIntervalSince1970: 1_800_000_000)
        let observed = fetched.addingTimeInterval(-120)
        // Возраст считается от более раннего observedAt: уже несвежо на границе 600 с.
        XCTAssertFalse(SnapshotPolicy.isFresh(fetchedAt: fetched, observedAt: observed,
            lastRefreshFailed: false, resetAt: nil, now: fetched.addingTimeInterval(599)))
    }

    func testRestoredFromKeepsOriginalFetchedAt() throws {
        // При восстановлении из файла исходное время получения сохраняется (§6).
        let original = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = UsageSnapshot(
            connection: connection(.kimi),
            source: "kimi.usages.v1",
            fetchedAt: original,
            quotas: []
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        let restored = try decoder.decode(UsageSnapshot.self, from: data)
        XCTAssertEqual(restored.fetchedAt, original)
        let now = original.addingTimeInterval(60 * 60)
        XCTAssertTrue(SnapshotPolicy.isFresh(
            fetchedAt: restored.fetchedAt, observedAt: restored.observedAt,
            lastRefreshFailed: false, resetAt: nil, now: now) == false)
    }

    // MARK: - QuotaValue: неизвестные значения не становятся нулём

    func testPercentFromProviderPercent() {
        XCTAssertEqual(QuotaValue.remainingPercent(42).percent, 42)
    }

    func testPercentFromNumeratorDenominator() {
        let value = QuotaValue.counts(remaining: 250, total: 1000, unit: "requests")
        XCTAssertEqual(value.percent, 25)
    }

    func testZeroDenominatorYieldsUnknown() {
        XCTAssertNil(QuotaValue.counts(remaining: 10, total: 0, unit: "requests").percent)
    }

    func testUnknownYieldsUnknown() {
        XCTAssertNil(QuotaValue.unknown.percent)
    }

    func testUnlimitedYieldsUnknown() {
        XCTAssertNil(QuotaValue.unlimited.percent)
    }

    func testOutOfRangePercentYieldsUnknown() {
        // Провайдер прислал 150% — некорректно, не превращаем в показатель.
        XCTAssertNil(QuotaValue.remainingPercent(150).percent)
    }

    func testNegativeFractionYieldsUnknown() {
        XCTAssertNil(QuotaValue.counts(remaining: -5, total: 100, unit: "credits").percent)
    }
}
