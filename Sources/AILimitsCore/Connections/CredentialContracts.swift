import Foundation

/// Источник авторизации подключения (план Task 3).
public enum CredentialSource: String, Codable, Sendable {
    /// Ключ, введённый пользователем вручную (OpenRouter Management Key, ключ Kimi, ключ Z.ai).
    case manualKey
    /// Разрешённое чтение локального входа Claude CLI (только после согласия).
    case claudeCLI
    /// Разрешённое чтение свежего CLI-токена Kimi Code (только после согласия).
    case kimiCLI
    /// Отдельный изолированный вход приложения для Codex.
    case codexIsolatedLogin
}

/// Характер чтения секрета: фоновые чтения не должны вызывать системные диалоги.
public enum CredentialInteraction: String, Sendable {
    case userInitiated
    case background
}

/// Аренда авторизации: не Codable, не выводит секрет, живёт только внутри адаптера.
/// Адаптер получает то, что нужно для запроса, но не сам секрет в открытом виде.
public struct AuthLease: Sendable {
    /// Готовый заголовок авторизации или материал для него.
    public let authorizer: @Sendable () -> String?

    public init(authorizer: @escaping @Sendable () -> String?) {
        self.authorizer = authorizer
    }
}

/// Контракт доступа к credentials. Реализация — KeychainVault (AILimitsMac).
public protocol CredentialAccess: Sendable {
    /// Вернуть аренду для подключения или типизированную ошибку.
    /// `consentRequired` — до явного согласия; `keychainLocked` — фоновое чтение заблокированной записи.
    func resolve(connection: ConnectionRecord, interaction: CredentialInteraction) async throws -> AuthLease
}
