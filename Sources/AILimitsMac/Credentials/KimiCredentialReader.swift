import Foundation
import AILimitsCore

/// Task 8, шаг 4: read-only чтение Kimi CLI-токена (~/.kimi-code/credentials/kimi-code.json)
/// или ручного ключа. Refresh token НЕ читается; файлы чужого CLI не изменяются;
/// device_id не создаётся (план Task 8; спецификация §5 Kimi).
public struct KimiCredentialReader: CredentialAccess {
    /// Корень Kimi CLI (инъекция для тестов; по умолчанию ~/.kimi-code).
    public let kimiHome: URL

    private let vault: any CredentialAccess

    public init(kimiHome: URL? = nil, vault: any CredentialAccess = KeychainVault()) {
        self.vault = vault
        if let kimiHome {
            self.kimiHome = kimiHome
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            self.kimiHome = home.appendingPathComponent(".kimi-code", isDirectory: true)
        }
    }

    private var credentialsURL: URL {
        kimiHome.appendingPathComponent("credentials/kimi-code.json")
    }

    public func resolve(connection: ConnectionRecord, interaction: CredentialInteraction) async throws -> AuthLease {
        switch connection.source {
        case .manualKey:
            // Ручной ключ хранится в собственном Keychain.
            return try await vault.resolve(connection: connection, interaction: interaction)
        case .kimiCLI:
            return try readCLI(interaction: interaction)
        default:
            throw ProviderError.unsupportedSource
        }
    }

    /// Свежий access_token из credentials/kimi-code.json. Refresh token игнорируется.
    package func readCLIForTest(interaction: CredentialInteraction) throws -> String {
        let path = credentialsURL.path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let type = attributes[.type] as? FileAttributeType,
              type == FileAttributeType.typeRegular else {
            // Обязательный файл отсутствует: предложение ключа в UI, не «ремонт» CLI.
            throw ProviderError.authenticationRequired
        }
        guard let data = try? Data(contentsOf: credentialsURL) else {
            throw ProviderError.permissionDenied
        }
        struct Payload: Decodable {
            let access_token: String?
            let refresh_token: String?
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let access = payload.access_token, !access.isEmpty else {
            throw ProviderError.authenticationRequired
        }
        // refresh_token намеренно не читается в lease (read-only контракт).
        return access
    }

    package func readCLI(interaction: CredentialInteraction) throws -> AuthLease {
        let access = try readCLIForTest(interaction: interaction)
        return AuthLease { access }
    }
}
