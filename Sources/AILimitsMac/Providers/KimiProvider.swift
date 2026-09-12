import Foundation
import AILimitsCore

/// Task 8, шаг 4: адаптер Kimi Code — GET /coding/v1/usages, Bearer.
/// Endpoint зафиксирован в EndpointPolicy; ключ Kimi Code ≠ баланс Moonshot API.
public struct KimiProvider: UsageProvider {
    public static let usagesURL = URL(string: "https://api.kimi.com/coding/v1/usages")!
    public static let sourceID = "kimi.usages.v1"

    public let id: ProviderID = .kimi

    private let transport: HTTPTransport
    private let credentials: CredentialAccess
    private let recordResolver: @Sendable (ConnectionID) async -> ConnectionRecord?
    private let clock: any AppClock

    public init(transport: HTTPTransport, credentials: CredentialAccess, clock: any AppClock = SystemClock(),
                recordResolver: @escaping @Sendable (ConnectionID) async -> ConnectionRecord? = { _ in nil }) {
        self.transport = transport
        self.credentials = credentials
        self.clock = clock
        self.recordResolver = recordResolver
    }

    public func fetch(connection: ConnectionID) async throws -> UsageSnapshot {
        guard EndpointPolicy.permits(provider: .kimi, url: Self.usagesURL) else {
            throw ProviderError.unsupportedSource
        }
        guard connection.provider == .kimi,
              let record = await recordResolver(connection), record.id == connection else {
            throw ProviderError.disconnected
        }
        guard record.source == .manualKey || record.source == .kimiCLI else {
            throw ProviderError.unsupportedSource
        }
        let lease = try await credentials.resolve(connection: record, interaction: .background)
        guard let authorization = lease.authorizer(), !authorization.isEmpty else {
            throw ProviderError.authenticationRequired
        }
        var request = URLRequest(url: Self.usagesURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(authorization)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let response = try await transport.send(request)
        guard response.status == 200 else {
            throw HTTPStatusPolicy.error(for: response.status, headers: response.headers, now: clock.now())
        }
        let quotas = try KimiParser.quotas(from: response.body)
        return UsageSnapshot(
            connection: connection,
            source: Self.sourceID,
            fetchedAt: clock.now(),
            quotas: quotas
        )
    }
}
