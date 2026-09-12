import XCTest
import AILimitsCore

/// Task 5: StateRepository — поколения, свежесть, отказ старых данных.
final class StateRepositoryTests: XCTestCase {
    private func connection(_ provider: ProviderID, _ gen: String) -> ConnectionID {
        var bytes = [UInt8](repeating: 0, count: 16)
        for (i, b) in gen.utf8.enumerated() where i < 16 { bytes[i] = b }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let uuid = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                              bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        return ConnectionID(provider: provider, generation: uuid)
    }

    private func record(_ connection: ConnectionID) -> ConnectionRecord {
        ConnectionRecord(id: connection, source: .manualKey, verifiedIdentityHash: nil)
    }

    private func snapshot(_ connection: ConnectionID, fetchedAt: Date, balance: Decimal? = nil) -> UsageSnapshot {
        UsageSnapshot(
            connection: connection,
            source: "openrouter.credits.v1",
            fetchedAt: fetchedAt,
            quotas: [],
            balanceUSD: balance
        )
    }

    func testAcceptAndLoadRoundTrip() async throws {
        let repository = StateRepository(clock: MockClock())
        let connection = connection(.openrouter, "gen-A")
        await repository.registerConnection(record(connection))
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        try await repository.accept(snapshot: snapshot(connection, fetchedAt: t, balance: 12))

        let loaded = await repository.snapshot(for: .openrouter)
        XCTAssertEqual(loaded?.connection, connection)
        XCTAssertEqual(loaded?.balanceUSD, 12)
        XCTAssertEqual(loaded?.fetchedAt, t)
    }

    /// Старое поколение (смена аккаунта) отбрасывается ДО сохранения.
    func testStaleGenerationRejected() async throws {
        let repository = StateRepository(clock: MockClock())
        let oldGen = connection(.openrouter, "gen-A")
        let newGen = connection(.openrouter, "gen-B")
        await repository.registerConnection(record(oldGen))
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        try await repository.accept(snapshot: snapshot(oldGen, fetchedAt: t, balance: 5))

        await repository.replaceConnection(newGen, provider: .openrouter)
        // Снимок старого поколения не принимается.
        do {
            try await repository.accept(snapshot: snapshot(oldGen, fetchedAt: t.addingTimeInterval(60), balance: 6))
            XCTFail("must reject old generation")
        } catch { /* ожидаемо */ }
        let loaded = await repository.snapshot(for: .openrouter)
        XCTAssertNil(loaded, "после replaceConnection старый кэш очищен")
    }

    /// Время получения из будущего отклоняется.
    func testFutureObservationRejected() async throws {
        let repository = StateRepository(clock: MockClock())
        let connection = connection(.openrouter, "gen-A")
        await repository.registerConnection(record(connection))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try await repository.accept(snapshot: snapshot(connection, fetchedAt: now, balance: 5))
        do {
            try await repository.accept(snapshot: snapshot(connection, fetchedAt: now.addingTimeInterval(3600), balance: 7))
            XCTFail("must reject future observation")
        } catch { /* ожидаемо */ }
        let loaded = await repository.snapshot(for: .openrouter)
        XCTAssertEqual(loaded?.balanceUSD, 5)
    }

    /// Время получения старше уже принятого — отклоняется.
    func testOlderFetchedAtRejected() async throws {
        let repository = StateRepository(clock: MockClock())
        let connection = connection(.openrouter, "gen-A")
        await repository.registerConnection(record(connection))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try await repository.accept(snapshot: snapshot(connection, fetchedAt: now, balance: 5))
        do {
            try await repository.accept(snapshot: snapshot(connection, fetchedAt: now.addingTimeInterval(-600), balance: 9))
            XCTFail("must reject older observation")
        } catch { /* ожидаемо */ }
        let loaded = await repository.snapshot(for: .openrouter)
        XCTAssertEqual(loaded?.balanceUSD, 5)
    }

    /// Ошибка не заменяет последний снимок.
    func testFailureKeepsLastSnapshot() async throws {
        let repository = StateRepository(clock: MockClock())
        let connection = connection(.openrouter, "gen-A")
        await repository.registerConnection(record(connection))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try await repository.accept(snapshot: snapshot(connection, fetchedAt: now, balance: 5))
        await repository.recordFailure(connection: connection, error: .network)
        let loaded = await repository.snapshot(for: .openrouter)
        XCTAssertEqual(loaded?.balanceUSD, 5)
        let failed = await repository.lastRefreshFailed(for: .openrouter)
        XCTAssertTrue(failed)
    }

    /// disconnect очищает данные провайдера.
    func testDisconnectClearsProvider() async throws {
        let repository = StateRepository(clock: MockClock())
        let connection = connection(.openrouter, "gen-A")
        await repository.registerConnection(record(connection))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try await repository.accept(snapshot: snapshot(connection, fetchedAt: now, balance: 5))
        await repository.disconnect(.openrouter)
        let loaded = await repository.snapshot(for: .openrouter)
        XCTAssertNil(loaded)
    }
}
