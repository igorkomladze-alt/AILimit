import Foundation
import AILimitsCore

public struct AlertPreference: Codable, Equatable, Sendable {
    public var warnings: Bool
    public var recovery: Bool
    public init(warnings: Bool = true, recovery: Bool = true) {
        self.warnings = warnings
        self.recovery = recovery
    }
}

/// Персистентное состояние уведомлений (Task 7/13 wiring).
/// Эпизоды порогов и outbox ожидающих событий переживают перезапуск (спецификация §8):
/// перевзвод, recovery и подавление повторов не сбрасываются рестартом приложения.
/// Секретов здесь нет и быть не может — только пороговые состояния и тексты событий.
public struct AlertStateStore: Codable, Equatable, Sendable {
    /// Денежные эпизоды по провайдерам (ключ — provider.rawValue).
    public var balanceEpisodes: [String: BalanceEpisode] = [:]
    /// Квотные эпизоды (ключ — "provider:quotaID").
    public var quotaEpisodes: [String: QuotaEpisode] = [:]
    /// События, ожидающие доставки в системный центр уведомлений.
    public var outbox: NotificationOutbox = NotificationOutbox()
    /// Пользовательское включение уведомлений. Системное разрешение запрашивается
    /// отдельно и только после явного действия (спецификация §8).
    public var notificationsEnabled = false
    /// Системное разрешение уже запрашивалось — повторных диалогов в фоне нет.
    public var permissionRequested = false
    /// Optional для совместимости с существующим alerts.json.
    public var preferences: [String: AlertPreference]?

    public init() {}

    /// Сброс эпизодов провайдера при смене поколения (новый аккаунт — чистая история).
    public mutating func reset(provider: ProviderID) {
        balanceEpisodes.removeValue(forKey: provider.rawValue)
        let prefix = "\(provider.rawValue):"
        quotaEpisodes = quotaEpisodes.filter { !$0.key.hasPrefix(prefix) }
        outbox.removeAll { $0.provider == provider }
    }
}

/// Типизированный файл alerts.json в каталоге состояния приложения.
public typealias AlertStateFile = AtomicJSONFile<AlertStateStore>

public extension AtomicJSONFile where Value == AlertStateStore {
    init(alertsIn directory: URL? = nil, fileName: String = "alerts.json") {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AILimits", isDirectory: true)
        self.init(directory: base, fileName: fileName)
    }
}
