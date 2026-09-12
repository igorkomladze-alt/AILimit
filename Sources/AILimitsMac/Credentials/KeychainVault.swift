import Foundation
import Security
import LocalAuthentication
import AILimitsCore

/// Хранилище собственных секретов: CredentialAccess + запись/удаление (инъекция для тестов).
public protocol SecretVault: CredentialAccess {
    func save(secret: Data, account: String) throws
    func delete(account: String) throws
}

/// Task 3, шаг 4: хранилище СВОБСТВЕННЫХ секретов в Keychain.
/// - Namespace строго `local.gutfresh.AILimits` — чужие items не читаются и не пишутся.
/// - Без kSecAttrSynchronizable (нет iCloud-синхронизации, спецификация §7).
/// - Fail-closed: фоновое чтение заблокированной записи → `.keychainLocked`, без диалога.
public struct KeychainVault: SecretVault {
    /// Проверка принадлежности service нашему namespace (план Task 3, шаг 5).
    public static func isOwnedService(_ service: String) -> Bool {
        service == KeychainVault.ownedService
    }

    public static let ownedService = "local.gutfresh.AILimits"

    public init() {}

    // MARK: - CredentialAccess

    public func resolve(connection: ConnectionRecord, interaction: CredentialInteraction) async throws -> AuthLease {
        let account = Self.account(for: connection)
        let data: Data? = try Self.read(account: account, interaction: interaction)
        return AuthLease { [data] in data.flatMap { String(data: $0, encoding: .utf8) } }
    }

    /// Account формата `provider:generation:purpose` (план Task 3, шаг 4).
    public static func account(for connection: ConnectionRecord, purpose: String = "key") -> String {
        "\(connection.id.provider.rawValue):\(connection.id.generation.uuidString):\(purpose)"
    }

    // MARK: - save / read / delete (только собственные items)

    public func save(secret: Data, account: String) throws {
        let service = Self.ownedService
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: secret,
            kSecAttrSynchronizable: false,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        // Замена существующего значения без дублей.
        let status = SecItemUpdate(
            [kSecClass: kSecClassGenericPassword,
             kSecAttrService: service,
             kSecAttrAccount: account,
             kSecAttrSynchronizable: false] as CFDictionary,
            [kSecValueData: secret] as CFDictionary
        )
        if status == errSecItemNotFound {
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw Self.map(status: addStatus) }
        } else if status != errSecSuccess {
            throw Self.map(status: status)
        }
    }

    public func read(account: String, interaction: CredentialInteraction) throws -> Data {
        try Self.read(account: account, interaction: interaction)
    }

    static func read(account: String, interaction: CredentialInteraction) throws -> Data {
        let service = ownedService
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecAttrSynchronizable: false
        ]
        // Фоновые чтения не показывают UI: заблокированная запись → ошибка, не диалог.
        if interaction == .background {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext] = context
        }
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw Self.map(status: status)
        }
        return data
    }

    public func delete(account: String) throws {
        let service = Self.ownedService
        let status = SecItemDelete(
            [kSecClass: kSecClassGenericPassword,
             kSecAttrService: service,
             kSecAttrAccount: account,
             kSecAttrSynchronizable: false] as CFDictionary
        )
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Self.map(status: status)
        }
    }

    /// Маппинг статусов Security в типизированные ошибки (план Task 3, шаг 4).
    static func map(status: OSStatus) -> ProviderError {
        switch status {
        case errSecItemNotFound:
            return .authenticationRequired
        case errSecAuthFailed:
            return .permissionDenied
        case errSecInteractionNotAllowed:
            return .keychainLocked
        default:
            return .keychainLocked
        }
    }
}
