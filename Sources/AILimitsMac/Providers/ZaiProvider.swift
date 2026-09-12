import Foundation
import AILimitsCore

/// Task 9: адаптер GLM/Z.ai — персональный международный Coding Plan.
/// Регион подтверждается пользователем при подключении; BigModel CN → unsupportedSource
/// без пробного запроса на другой домен (спецификация §5 Z.ai).
public struct ZaiProvider: UsageProvider {
    public static let quotaURL = URL(string: "https://api.z.ai/api/monitor/usage/quota/limit")!
    public static let sourceID = "zai.quota.v1"

    public let id: ProviderID = .zai

    private let transport: HTTPTransport
    private let credentials: CredentialAccess
    private let clock: any AppClock

    public init(transport: HTTPTransport, credentials: CredentialAccess, clock: any AppClock = SystemClock()) {
        self.transport = transport
        self.credentials = credentials
        self.clock = clock
    }

    public func fetch(connection: ConnectionID) async throws -> UsageSnapshot {
        guard EndpointPolicy.permits(provider: .zai, url: Self.quotaURL) else {
            throw ProviderError.unsupportedSource
        }
        let record = ConnectionRecord(id: connection, source: .manualKey, verifiedIdentityHash: nil)
        let lease = try await credentials.resolve(connection: record, interaction: .background)
        guard let authorization = lease.authorizer(), !authorization.isEmpty else {
            throw ProviderError.authenticationRequired
        }
        var request = URLRequest(url: Self.quotaURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(authorization)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let response = try await transport.send(request)
        guard response.status == 200 else {
            throw HTTPStatusPolicy.error(for: response.status, headers: response.headers, now: clock.now())
        }
        let quotas = try ZaiParser.quotas(from: response.body, now: clock.now())
        return UsageSnapshot(
            connection: connection,
            source: Self.sourceID,
            fetchedAt: clock.now(),
            quotas: quotas
        )
    }
}
