import Foundation
import AILimitsCore

/// Task 3, шаг 4: согласия на конкретный источник конкретного провайдера.
/// До согласия даже существование локального файла не проверяется (спецификация §3).
public struct ConsentStore: Sendable {
    /// Ключ: `provider:sourceDescriptor`. Значение: дата согласия.
    private var consents: [String: Date]

    public init(consents: [String: Date] = [:]) {
        self.consents = consents
    }

    /// Дано ли согласие на чтение конкретного source-дескриптора этого провайдера.
    public func hasConsent(provider: ProviderID, sourceDescriptor: String) -> Bool {
        consents[consentKey(provider: provider, sourceDescriptor: sourceDescriptor)] != nil
    }

    /// Зафиксировать согласие (только явное действие пользователя в UI).
    public mutating func grant(provider: ProviderID, sourceDescriptor: String, now: Date) {
        consents[consentKey(provider: provider, sourceDescriptor: sourceDescriptor)] = now
    }

    /// Отозвать согласие: фоновые попытки прекращаются, диалоги не повторяются.
    public mutating func revoke(provider: ProviderID, sourceDescriptor: String) {
        consents.removeValue(forKey: consentKey(provider: provider, sourceDescriptor: sourceDescriptor))
    }

    private func consentKey(provider: ProviderID, sourceDescriptor: String) -> String {
        "\(provider.rawValue):\(sourceDescriptor)"
    }
}
