import Foundation
import AILimitsCore

/// Task 10: адаптер Claude — GET /api/oauth/usage, Bearer + beta header (R4).
public struct ClaudeProvider: UsageProvider {
    public static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    public static let sourceID = "claude.usage.v1"

    public let id: ProviderID = .claude

    private let transport: HTTPTransport
    private let credentials: CredentialAccess
    private let clock: any AppClock

    public init(transport: HTTPTransport, credentials: CredentialAccess, clock: any AppClock = SystemClock()) {
        self.transport = transport
        self.credentials = credentials
        self.clock = clock
    }

    public func fetch(connection: ConnectionID) async throws -> UsageSnapshot {
        guard EndpointPolicy.permits(provider: .claude, url: Self.usageURL) else {
            throw ProviderError.unsupportedSource
        }
        let record = ConnectionRecord(id: connection, source: .claudeCLI, verifiedIdentityHash: nil)
        let lease = try await credentials.resolve(connection: record, interaction: .background)
        guard let authorization = lease.authorizer(), !authorization.isEmpty else {
            throw ProviderError.authenticationRequired
        }
        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(authorization)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let response = try await transport.send(request)
        guard response.status == 200 else {
            throw HTTPStatusPolicy.error(for: response.status, headers: response.headers, now: clock.now())
        }
        let quotas = try ClaudeParser.quotas(from: response.body)
        return UsageSnapshot(
            connection: connection,
            source: Self.sourceID,
            fetchedAt: clock.now(),
            quotas: quotas
        )
    }
}
