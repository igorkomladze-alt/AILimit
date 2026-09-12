import Foundation

/// Предупреждение о низком балансе.
public enum BalanceAlert: Equatable, Sendable {
    case lowBalance
}

/// Эпизод денежного порога. Codable — переживает перезапуск (спецификация §8).
public struct BalanceEpisode: Equatable, Codable, Sendable {
    public var isBelow: Bool = false

    public init(isBelow: Bool = false) {
        self.isBelow = isBelow
    }
}

/// Чистое правило денежного порога без Double (план Task 7).
/// Строго ниже порога: ровно threshold — предупреждения нет.
public enum BalanceAlertReducer {
    /// `validFresh == false` (ошибка/устаревшие данные) — состояние не меняется, nil.
    /// Событие только при переходе сверху вниз: below && !state.isBelow.
    @discardableResult
    public static func observe(
        balance: Decimal,
        validFresh: Bool,
        threshold: Decimal = Decimal(3),
        state: inout BalanceEpisode
    ) -> BalanceAlert? {
        guard validFresh, !balance.isNaN, !threshold.isNaN, threshold >= 0 else { return nil }
        let below = balance < threshold
        defer { state.isBelow = below }
        return below && !state.isBelow ? .lowBalance : nil
    }
}

/// Эпизод порогов одной квоты.
public struct QuotaEpisode: Equatable, Codable, Sendable {
    /// Уже обработанные пороги текущего эпизода (проценты остатка).
    public var sentThresholds: Set<Int>
    /// Был ли отправлен хотя бы один порог (условие recovery).
    public var hadWarning: Bool
    /// Восстановление подтверждено (выше recovery-порога после предупреждения).
    public var isRecovered: Bool

    public init(
        sentThresholds: Set<Int> = [],
        hadWarning: Bool = false,
        isRecovered: Bool = false
    ) {
        self.sentThresholds = sentThresholds
        self.hadWarning = hadWarning
        self.isRecovered = isRecovered
    }
}

/// Реестр эпизодов (осталось как actor-фасад для переносимости тестов).
/// Работает только со свежими валидными данными (спецификация §8).
public actor WarningLedger {
    private var balanceEpisodes: [ProviderID: BalanceEpisode] = [:]
    private var quotaEpisodes: [String: QuotaEpisode] = [:]
    private let clock: any AppClock

    /// Пороги остатка, % (спецификация §8: 20% и 5%).
    public static let subscriptionThresholds: [Int] = [20, 5]

    public init(clock: (any AppClock)? = nil) {
        self.clock = clock ?? SystemClock()
    }

    // MARK: - Денежный порог OpenRouter

    /// Оценка баланса. Возвращает true, если нужно отправить уведомление.
    /// nil-баланс (ошибка/устаревание) состояние не меняет.
    public func evaluateBalance(provider: ProviderID, balanceUSD: Decimal?) throws -> Bool {
        guard let balance = balanceUSD else { return false }
        var episode = balanceEpisodes[provider] ?? BalanceEpisode()
        let alert = BalanceAlertReducer.observe(balance: balance, validFresh: true, state: &episode)
        balanceEpisodes[provider] = episode
        return alert != nil
    }

    // MARK: - Процентные пороги подписок

    /// Оценка остатка квоты. nil — состояние не меняется.
    /// Возвращает наиболее критичный новый порог: не более одного события за обновление.
    public func evaluateQuota(provider: ProviderID, quotaID: String, remainingPercent: Double?) throws -> [Int] {
        guard let percent = remainingPercent else { return [] }
        let key = "\(provider.rawValue):\(quotaID)"
        var episode = quotaEpisodes[key] ?? QuotaEpisode()

        let crossed = WarningLedger.subscriptionThresholds
            .filter { percent <= Double($0) && !episode.sentThresholds.contains($0) }
        episode.sentThresholds.formUnion(crossed)
        // Перевзвод порога: значение выше порога убирает его из обработанных.
        episode.sentThresholds = episode.sentThresholds.filter { percent <= Double($0) }

        guard !crossed.isEmpty else {
            quotaEpisodes[key] = episode
            return []
        }
        episode.hadWarning = true
        quotaEpisodes[key] = episode
        // Одно наиболее критичное событие за обновление.
        return [crossed.min()!]
    }

    /// Восстановление: подтверждено свежим значением выше recovery-порога.
    public func recoveryThreshold(provider: ProviderID, quotaID: String, remainingPercent: Double?) -> Bool {
        guard let percent = remainingPercent, percent > Double(Self.subscriptionThresholds[0]) else { return false }
        let key = "\(provider.rawValue):\(quotaID)"
        guard let episode = quotaEpisodes[key], episode.hadWarning else { return false }
        quotaEpisodes.removeValue(forKey: key)
        return true
    }

    /// Явный сброс эпизодов (смена аккаунта / поколения подключения).
    public func reset(provider: ProviderID, quotaID: String?) {
        if let quotaID {
            quotaEpisodes.removeValue(forKey: "\(provider.rawValue):\(quotaID)")
        } else {
            balanceEpisodes.removeValue(forKey: provider)
            let prefix = "\(provider.rawValue):"
            quotaEpisodes = quotaEpisodes.filter { !$0.key.hasPrefix(prefix) }
        }
    }
}
