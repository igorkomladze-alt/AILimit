import Foundation

/// Task 1, раздел 3 плана. Стабильный идентификатор провайдера.
public enum ProviderID: String, CaseIterable, Hashable, Codable, Sendable {
    case claude, codex, kimi, zai, openrouter

    /// Порядок отображения по умолчанию (спецификация §3).
    public var displayOrder: Int {
        switch self {
        case .claude: return 0
        case .codex: return 1
        case .kimi: return 2
        case .zai: return 3
        case .openrouter: return 4
        }
    }

    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .kimi: return "Kimi Code"
        case .zai: return "GLM / Z.ai"
        case .openrouter: return "OpenRouter"
        }
    }
}

/// Идентичность подключения: провайдер + поколение (UUID). Смена аккаунта — новое поколение.
public struct ConnectionID: Hashable, Codable, Sendable {
    public let provider: ProviderID
    public let generation: UUID

    public init(provider: ProviderID, generation: UUID) {
        self.provider = provider
        self.generation = generation
    }
}

/// Три различных состояния величины: неизвестно / безлимит / конкретное значение.
/// Спецификация §6: отсутствие поля, ноль и безлимит — разные состояния.
public enum QuotaValue: Equatable, Codable, Sendable {
    case unknown
    case unlimited
    case remainingPercent(Decimal)
    case counts(remaining: Decimal, total: Decimal, unit: String)

    /// Валидированный процент остатка. Некорректное значение → nil, не 0 и не 100.
    public var percent: Decimal? {
        switch self {
        case .unknown, .unlimited:
            return nil
        case .remainingPercent(let value):
            return Self.isValidPercent(value) ? value : nil
        case .counts(let remaining, let total, _):
            guard !remaining.isNaN, !total.isNaN,
                  total > 0, remaining >= 0, remaining <= total else { return nil }
            let value = remaining / total * 100
            return Self.isValidPercent(value) ? value : nil
        }
    }

    private static func isValidPercent(_ value: Decimal) -> Bool {
        !value.isNaN && value >= 0 && value <= 100
    }
}
