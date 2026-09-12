import Foundation

/// Task 5, шаг 4: атомарный envelope версии 1.
/// Содержит безопасные данные: подключения, снимки, состояние ошибок.
/// НЕ содержит credential payload, полный email, HTTP body, raw URL (план §Task 5).
public struct AppEnvelope: Codable, Sendable {
    /// Версия схемы. Неизвестная версия → безопасный старт без значений.
    public static let currentVersion = 1

    public let version: Int
    /// Последние принятые снимки по провайдерам.
    public var snapshots: [String: StoredSnapshot]
    /// Активные подключения (провайдер → подключение без секретов).
    public var connections: [String: StoredConnection]

    public init(
        version: Int = AppEnvelope.currentVersion,
        snapshots: [String: StoredSnapshot] = [:],
        connections: [String: StoredConnection] = [:]
    ) {
        self.version = version
        self.snapshots = snapshots
        self.connections = connections
    }

    /// Снимок, пригодный для хранения: без секретов, с исходным fetchedAt.
    public struct StoredSnapshot: Codable, Sendable {
        public let snapshot: UsageSnapshot

        public init(snapshot: UsageSnapshot) {
            self.snapshot = snapshot
        }
    }

    /// Подключение: provider, поколение, источник, digest идентичности (не сам секрет).
    public struct StoredConnection: Codable, Sendable {
        public let provider: String
        public let generation: UUID
        public let source: String
        public let verifiedIdentityHash: String?

        public init(record: ConnectionRecord) {
            self.provider = record.id.provider.rawValue
            self.generation = record.id.generation
            self.source = record.source.rawValue
            self.verifiedIdentityHash = record.verifiedIdentityHash
        }

        public func record() -> ConnectionRecord? {
            guard let provider = ProviderID(rawValue: provider),
                  let source = CredentialSource(rawValue: source) else { return nil }
            return ConnectionRecord(
                id: ConnectionID(provider: provider, generation: generation),
                source: source,
                verifiedIdentityHash: verifiedIdentityHash
            )
        }
    }
}
