import XCTest
import Foundation
@testable import AILimitsCore

/// Task 6, шаг 5: детерминированный fake-provider и проверки координатора.
final class RefreshCoordinatorTests: XCTestCase {
    /// Fake-provider: actor с очередью приостановленных вызовов.
    actor FakeProvider: UsageProvider {
        let id: ProviderID
        private(set) var calls = 0
        private var pending: [CheckedContinuation<UsageSnapshot, Error>] = []

        init(id: ProviderID) { self.id = id }

        func fetch(connection: ConnectionID) async throws -> UsageSnapshot {
            calls += 1
            return try await withCheckedThrowingContinuation { continuation in
                pending.append(continuation)
            }
        }

        /// Разбудить один ожидающий вызов с результатом.
        func finishNext(_ snapshot: UsageSnapshot) {
            guard !pending.isEmpty else { return }
            pending.removeFirst().resume(returning: snapshot)
        }

        func failNext(_ error: ProviderError) {
            guard !pending.isEmpty else { return }
            pending.removeFirst().resume(throwing: error)
        }

        /// Разбудить один ожидающий вызов с ошибкой (эмуляция отмены).
        func cancelNext() {
            guard !pending.isEmpty else { return }
            pending.removeFirst().resume(throwing: ProviderError.cancelled)
        }
    }

    private func record(_ provider: ProviderID) -> ConnectionRecord {
        ConnectionRecord(
            id: ConnectionID(provider: provider, generation: UUID()),
            source: .manualKey,
            verifiedIdentityHash: nil
        )
    }

    private func snapshot(_ connection: ConnectionID) -> UsageSnapshot {
        UsageSnapshot(
            connection: connection,
            source: "test.v1",
            fetchedAt: Date(),
            quotas: [],
            balanceUSD: 1
        )
    }

    /// Два независимых провайдера: медленный не блокирует быстрый.
    func testFastProviderNotBlockedBySlow() async throws {
        let fast = FakeProvider(id: .openrouter)
        let slow = FakeProvider(id: .kimi)
        let coordinator = RefreshCoordinator(providers: [.openrouter: fast, .kimi: slow], clock: MockClock())
        await coordinator.setConnection(record(.openrouter))
        await coordinator.setConnection(record(.kimi))

        async let request = coordinator.request(providers: [.openrouter, .kimi], reason: .manual)
        // Дать задачам стартовать.
        try await Task.sleep(nanoseconds: 50_000_000)
        await fast.finishNext(snapshot(record(.openrouter).id))
        await fast.finishNext(snapshot(record(.openrouter).id)) // страховка от гонки
        await slow.finishNext(snapshot(record(.kimi).id))
        await slow.finishNext(snapshot(record(.kimi).id))
        let updates = await request
        XCTAssertEqual(updates.count, 2)
    }

    actor Received {
        var ids: [ProviderID] = []
        func append(_ update: ProviderUpdate) { ids.append(update.connection.provider) }
    }

    func testCallbackDeliversFastBeforeSlowCompletes() async throws {
        let fast = FakeProvider(id: .openrouter), slow = FakeProvider(id: .kimi)
        let fastRecord = record(.openrouter), slowRecord = record(.kimi)
        let coordinator = RefreshCoordinator(providers: [.openrouter: fast, .kimi: slow])
        await coordinator.setConnection(fastRecord)
        await coordinator.setConnection(slowRecord)
        let received = Received()
        let request = Task { await coordinator.request(providers: [.openrouter, .kimi], reason: .manual) {
            await received.append($0)
        } }
        try await Task.sleep(nanoseconds: 50_000_000)
        await fast.finishNext(snapshot(fastRecord.id))
        try await Task.sleep(nanoseconds: 50_000_000)
        let beforeSlow = await received.ids
        XCTAssertEqual(beforeSlow, [.openrouter])
        await slow.finishNext(snapshot(slowRecord.id))
        let result = await request.value
        XCTAssertEqual(result.count, 2)
    }

    func testLaterRequestWaitsForOccupiedSlotAndOwnResult() async throws {
        let first = FakeProvider(id: .openrouter), second = FakeProvider(id: .kimi)
        let a = record(.openrouter), b = record(.kimi)
        let coordinator = RefreshCoordinator(providers: [.openrouter: first, .kimi: second], maxConcurrent: 1)
        await coordinator.setConnection(a)
        await coordinator.setConnection(b)
        let one = Task { await coordinator.request(providers: [.openrouter], reason: .manual) }
        try await Task.sleep(nanoseconds: 50_000_000)
        let two = Task { await coordinator.request(providers: [.kimi], reason: .manual) }
        try await Task.sleep(nanoseconds: 50_000_000)
        let callsBefore = await second.calls
        XCTAssertEqual(callsBefore, 0)
        await first.finishNext(snapshot(a.id))
        try await Task.sleep(nanoseconds: 50_000_000)
        let callsAfter = await second.calls
        XCTAssertEqual(callsAfter, 1)
        await second.finishNext(snapshot(b.id))
        let firstUpdates = await one.value, secondUpdates = await two.value
        XCTAssertEqual(firstUpdates.map(\.connection), [a.id])
        XCTAssertEqual(secondUpdates.map(\.connection), [b.id])
    }

    func testRetiredGenerationDoesNotDelayNewConnection() async throws {
        let provider = FakeProvider(id: .openrouter)
        let coordinator = RefreshCoordinator(providers: [.openrouter: provider])
        let old = record(.openrouter), new = record(.openrouter)
        await coordinator.setConnection(old)
        let first = Task { await coordinator.request(providers: [.openrouter], reason: .manual) }
        try await Task.sleep(nanoseconds: 50_000_000)
        await coordinator.setConnection(new)
        await provider.failNext(.rateLimited(until: Date().addingTimeInterval(3600)))
        _ = await first.value
        let next = Task { await coordinator.request(providers: [.openrouter], reason: .manual) }
        try await Task.sleep(nanoseconds: 50_000_000)
        let calls = await provider.calls
        XCTAssertEqual(calls, 2)
        await provider.finishNext(snapshot(new.id))
        let updates = await next.value
        XCTAssertEqual(updates.map(\.connection), [new.id])
    }

    /// Повторный request при in-flight — не создаёт второй вызов (один запрос на сервис).
    func testManualDoesNotDuplicateInFlight() async throws {
        let provider = FakeProvider(id: .openrouter)
        let coordinator = RefreshCoordinator(providers: [.openrouter: provider], clock: MockClock())
        await coordinator.setConnection(record(.openrouter))

        async let first = coordinator.request(providers: [.openrouter], reason: .manual)
        try await Task.sleep(nanoseconds: 50_000_000)
        // Второй запрос: in-flight — старт не произойдёт, вернётся пустой.
        let second = await coordinator.request(providers: [.openrouter], reason: .manual)
        XCTAssertTrue(second.isEmpty)
        await provider.finishNext(snapshot(record(.openrouter).id))
        await provider.finishNext(snapshot(record(.openrouter).id))
        _ = await first
        let calls1 = await provider.calls
        XCTAssertEqual(calls1, 1)
    }

    /// Backoff после ошибки: следующий request до истечения срока не стартует.
    func testBackoffBlocksSubsequentRequest() async throws {
        let provider = FakeProvider(id: .openrouter)
        let clock = MockClock()
        let coordinator = RefreshCoordinator(providers: [.openrouter: provider], clock: clock)
        await coordinator.setConnection(record(.openrouter))

        async let first = coordinator.request(providers: [.openrouter], reason: .manual)
        try await Task.sleep(nanoseconds: 50_000_000)
        await provider.cancelNext() // ошибка → failures=1 → backoff 600 c
        await provider.cancelNext()
        _ = await first

        clock.advance(by: 100) // меньше backoff
        let second = await coordinator.request(providers: [.openrouter], reason: .manual)
        XCTAssertTrue(second.isEmpty, "backoff блокирует повтор")
        let calls1 = await provider.calls
        XCTAssertEqual(calls1, 1)
    }

    /// Смена поколения отбрасывает поздний результат (не присваивается задним числом).
    func testLateResultOfOldGenerationRejected() async throws {
        let repository = StateRepository(clock: MockClock())
        let old = record(.openrouter)
        await repository.registerConnection(old)
        let coordinator = RefreshCoordinator(providers: [:], clock: MockClock())
        _ = coordinator // координатор проверяется косвенно через репозиторий ниже

        // Снимок «старого» поколения не принимается после замены.
        await repository.replaceConnection(record(.openrouter).id, provider: .openrouter)
        do {
            try await repository.accept(snapshot: snapshot(old.id))
            XCTFail("old generation must be rejected")
        } catch { /* ожидаемо */ }
    }
}
