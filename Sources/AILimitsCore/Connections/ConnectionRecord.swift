import Foundation

/// Task 3, шаг 3: решение о поколении подключения.
/// Повторное подключение к тому же ДОКАЗАННОМУ аккаунту сохраняет историю
/// предупреждений; во всех прочих случаях — новое поколение и очистка состояния.
public enum ConnectionPolicy {
    /// Поколение можно сохранить только при двух непустых совпадающих идентичностях.
    /// nil-идентичность источника не доказывает смены и не доказывает совпадения:
    /// состояние не смешивается (спецификация §3) — новое поколение.
    public static func canPreserveGeneration(oldIdentity: String?, newIdentity: String?) -> Bool {
        guard let oldIdentity, let newIdentity, !oldIdentity.isEmpty else { return false }
        return oldIdentity == newIdentity
    }
}

/// Одна запись подключения. На сервис — одна активная (спецификация §3).
public struct ConnectionRecord: Codable, Hashable, Sendable {
    public let id: ConnectionID
    /// Источник авторизации: manualKey / claudeCLI / kimiCLI / codexIsolatedLogin.
    public let source: CredentialSource
    /// Локальный digest идентичности (не email, не токен). nil — личность не подтверждена.
    public let verifiedIdentityHash: String?

    public init(id: ConnectionID, source: CredentialSource, verifiedIdentityHash: String?) {
        self.id = id
        self.source = source
        self.verifiedIdentityHash = verifiedIdentityHash
    }
}
