import Foundation

/// Task 5, шаг 4: репозиторий состояния. Actor — запись сериализована.
/// Правила принятия: то же поколение, время получения не из будущего и не старше принятого.
public actor StateRepository {
    private var envelope: AppEnvelope
    private var failures: [String: Bool] = [:]
    /// Активные поколения: снимок другого поколения отбрасывается до сохранения.
    private var activeGenerations: [String: UUID] = [:]
    private let clock: any AppClock

    public init(envelope: AppEnvelope = AppEnvelope(), clock: (any AppClock)? = nil) {
        self.envelope = envelope
        self.clock = clock ?? SystemClock()
        for (provider, stored) in envelope.connections {
            activeGenerations[provider] = stored.generation
        }
    }

    // MARK: - Чтение

    public func snapshot(for provider: ProviderID) -> UsageSnapshot? {
        envelope.snapshots[provider.rawValue]?.snapshot
    }

    public func connection(for provider: ProviderID) -> ConnectionRecord? {
        envelope.connections[provider.rawValue]?.record()
    }

    public func lastRefreshFailed(for provider: ProviderID) -> Bool {
        failures[provider.rawValue] ?? false
    }

    // MARK: - Запись

    /// Принять снимок. Отбрасывается: чужое поколение, время из будущего,
    /// время старше уже принятого (план Task 5, шаг 3).
    public func accept(snapshot: UsageSnapshot) throws {
        let key = snapshot.connection.provider.rawValue
        // Активное поколение: снимки прежних поколений не смешиваются (спецификация §3).
        guard let active = activeGenerations[key], active == snapshot.connection.generation else {
            throw ProviderError.disconnected
        }
        // Не из будущего.
        let now = clock.now()
        guard snapshot.fetchedAt <= now else { throw ProviderError.invalidData }
        // Не старше уже принятого.
        if let existing = envelope.snapshots[key]?.snapshot, snapshot.fetchedAt < existing.fetchedAt {
            throw ProviderError.invalidData
        }
        envelope.snapshots[key] = AppEnvelope.StoredSnapshot(snapshot: snapshot)
        failures[key] = false
    }

    /// Зафиксировать неудачу актуального обновления (последний снимок остаётся).
    public func recordFailure(connection: ConnectionID, error: ProviderError) {
        failures[connection.provider.rawValue] = true
    }

    /// Явная замена подключения: новое поколение, старые данные провайдера очищаются
    /// (спецификация §3: замена аккаунта очищает кэш и состояние предупреждений).
    public func replaceConnection(_ connection: ConnectionID, provider: ProviderID) {
        let key = provider.rawValue
        activeGenerations[key] = connection.generation
        envelope.snapshots.removeValue(forKey: key)
        failures[key] = false
    }

    public func registerConnection(_ record: ConnectionRecord) {
        let key = record.id.provider.rawValue
        activeGenerations[key] = record.id.generation
        envelope.connections[key] = AppEnvelope.StoredConnection(record: record)
    }

    /// Отключение: снимок и подключение удаляются.
    public func disconnect(_ provider: ProviderID) {
        let key = provider.rawValue
        envelope.snapshots.removeValue(forKey: key)
        envelope.connections.removeValue(forKey: key)
        activeGenerations.removeValue(forKey: key)
        failures.removeValue(forKey: key)
    }

    /// Экспорт текущего envelope для атомарной записи на диск (Task 13 wiring).
    /// Возвращает копию значения — мутации снаружи невозможны.
    public func export() -> AppEnvelope {
        envelope
    }
}
