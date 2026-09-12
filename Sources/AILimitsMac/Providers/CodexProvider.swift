import Foundation
import AILimitsCore

/// Task 11+12: адаптер Codex через изолированный app-server (JSONL RPC, read-only).
/// Генерации, инструменты и кредит-операции не вызываются — allowlist poll-методов.
public struct CodexProvider: UsageProvider {
    public static let sourceID = "codex.rateLimits.v1"

    public let id: ProviderID = .codex

    private let server: CodexServerController
    private let clock: any AppClock

    public init(server: CodexServerController, clock: any AppClock = SystemClock()) {
        self.server = server
        self.clock = clock
    }

    public func fetch(connection: ConnectionID) async throws -> UsageSnapshot {
        let result = try await server.readRateLimits()
        let quotas = try CodexParser.quotas(fromResult: result)
        return UsageSnapshot(
            connection: connection,
            source: Self.sourceID,
            fetchedAt: clock.now(),
            quotas: quotas
        )
    }
}
