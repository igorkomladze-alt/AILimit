import Foundation
import AILimitsCore

/// Task 4, шаг 5: адаптер OpenRouter — чтение баланса через /api/v1/credits.
public struct OpenRouterProvider: UsageProvider {
    public static let creditsURL = URL(string: "https://openrouter.ai/api/v1/credits")!
    public static let sourceID = "openrouter.credits.v1"

    public let id: ProviderID = .openrouter

    private let transport: HTTPTransport
    private let credentials: CredentialAccess
    private let clock: any AppClock

    public init(transport: HTTPTransport, credentials: CredentialAccess, clock: any AppClock = SystemClock()) {
        self.transport = transport
        self.credentials = credentials
        self.clock = clock
    }

    public func fetch(connection: ConnectionID) async throws -> UsageSnapshot {
        // Ключ добавляется ТОЛЬКО после allowlist-проверки (план Task 4, шаг 4).
        guard EndpointPolicy.permits(provider: .openrouter, url: Self.creditsURL) else {
            throw ProviderError.unsupportedSource
        }
        let record = ConnectionRecord(id: connection, source: .manualKey, verifiedIdentityHash: nil)
        let lease = try await credentials.resolve(connection: record, interaction: .background)
        guard let authorization = lease.authorizer(), !authorization.isEmpty else {
            throw ProviderError.authenticationRequired
        }

        var request = URLRequest(url: Self.creditsURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(authorization)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let response = try await transport.send(request)
        guard response.status == 200 else {
            throw HTTPStatusPolicy.error(for: response.status, headers: response.headers, now: clock.now())
        }
        // Только JSON: HTML-страница со статусом 200 отклоняется.
        guard let contentType = response.headers.first(where: { $0.key.lowercased() == "content-type" })?.value,
              contentType.lowercased().contains("json") else {
            throw ProviderError.incompatibleSchema
        }

        let balance = try OpenRouterParser.balance(from: response.body)
        return UsageSnapshot(
            connection: connection,
            source: Self.sourceID,
            fetchedAt: clock.now(),
            quotas: [],
            balanceUSD: balance
        )
    }
}
