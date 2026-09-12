import Foundation

/// Утверждённые настройки по умолчанию (спецификация §7/§8, план Task 1).
public struct AppSettings: Equatable, Codable, Sendable {
    /// Штатный интервал опроса: 5 минут.
    public let refreshSeconds: Int
    /// Порог устаревания данных: 10 минут.
    public let staleSeconds: Int
    /// Timeout адаптера: 30 секунд.
    public let timeoutSeconds: Int
    /// Не более трёх одновременно активных адаптеров.
    public let maxConcurrent: Int
    /// Автозапуск при входе, исходно выключен.
    public let launchAtLogin: Bool
    /// Порог OpenRouter: строго ниже $3.00 (Decimal, не Double).
    public let openRouterThresholdUSD: Decimal

    public init(
        refreshSeconds: Int = 300,
        staleSeconds: Int = 600,
        timeoutSeconds: Int = 30,
        maxConcurrent: Int = 3,
        launchAtLogin: Bool = false,
        openRouterThresholdUSD: Decimal = Decimal(3)
    ) {
        self.refreshSeconds = refreshSeconds
        self.staleSeconds = staleSeconds
        self.timeoutSeconds = timeoutSeconds
        self.maxConcurrent = maxConcurrent
        self.launchAtLogin = launchAtLogin
        self.openRouterThresholdUSD = openRouterThresholdUSD
    }

    public static let defaults = AppSettings()
}
