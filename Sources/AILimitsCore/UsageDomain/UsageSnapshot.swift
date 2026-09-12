import Foundation

/// Типизированные ошибки провайдера (план, раздел 3). Не содержат секретов и сырых ответов.
public enum ProviderError: Error, Equatable, Codable, Sendable {
    case disconnected
    case consentRequired
    case authenticationRequired
    case permissionDenied
    case keychainLocked
    case dependencyMissing
    case unsupportedSource
    case incompatibleSchema
    case invalidData
    case network
    case timeout
    case cancelled
    case rateLimited(until: Date)
    case server(status: Int)
}

/// Одна квота одного провайдера.
public struct UsageQuota: Identifiable, Equatable, Codable, Sendable {
    public let id: String
    public let title: String
    public let scope: String?
    public let value: QuotaValue
    public let windowSeconds: TimeInterval?
    public let resetsAt: Date?

    public init(
        id: String,
        title: String,
        scope: String? = nil,
        value: QuotaValue,
        windowSeconds: TimeInterval? = nil,
        resetsAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.scope = scope
        self.value = value
        self.windowSeconds = windowSeconds
        self.resetsAt = resetsAt
    }
}

/// Снимок состояния провайдера. fetchedAt — время фактического получения у источника;
/// при восстановлении из кэша сохраняется исходное значение (спецификация §6).
public struct UsageSnapshot: Equatable, Codable, Sendable {
    public let connection: ConnectionID
    /// Безопасный фиксированный идентификатор источника (например, "openrouter.credits.v1").
    public let source: String
    public let fetchedAt: Date
    /// Время наблюдения провайдера, если оно реально возвращено; не выводится из кэша.
    public let observedAt: Date?
    public let quotas: [UsageQuota]
    /// Денежный баланс в USD, только OpenRouter. Decimal, не Double.
    public let balanceUSD: Decimal?

    public init(
        connection: ConnectionID,
        source: String,
        fetchedAt: Date,
        observedAt: Date? = nil,
        quotas: [UsageQuota],
        balanceUSD: Decimal? = nil
    ) {
        self.connection = connection
        self.source = source
        self.fetchedAt = fetchedAt
        self.observedAt = observedAt
        self.quotas = quotas
        self.balanceUSD = balanceUSD
    }
}

/// Протокол адаптера провайдера (план, раздел 3).
public protocol UsageProvider: Sendable {
    var id: ProviderID { get }
    func fetch(connection: ConnectionID) async throws -> UsageSnapshot
}
