import Foundation
import Security
import LocalAuthentication
import AILimitsCore

/// Read-only Claude Code OAuth import. Interactive access is used only by the explicit
/// connect action; registered connections use noninteractive background reads.
/// Schema reference: CodexBar 6b83e08637de85f11887934fb37e1bf7db559e01,
/// ClaudeOAuthCredentialModels.swift. No refresh, writes or shell processes.
public struct ClaudeCredentialReader: CredentialAccess {
    public let claudeHome: URL
    private let keychainRead: @Sendable (CredentialInteraction) throws -> Data?
    private let clock: any AppClock

    public init(claudeHome: URL? = nil, clock: any AppClock = SystemClock(),
                keychainRead: (@Sendable (CredentialInteraction) throws -> Data?)? = nil) {
        self.claudeHome = claudeHome ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
        self.clock = clock
        self.keychainRead = keychainRead ?? Self.readKeychain
    }

    public func resolve(connection: ConnectionRecord, interaction: CredentialInteraction) async throws -> AuthLease {
        guard connection.id.provider == .claude, connection.source == .claudeCLI else {
            throw ProviderError.unsupportedSource
        }
        let access = try readForTest(interaction: interaction)
        return AuthLease { access }
    }

    /// The caller supplies explicit user interaction only from the connect button.
    package func readForTest(interaction: CredentialInteraction) throws -> String {
        let data: Data
        if let stored = try keychainRead(interaction) {
            data = stored
        } else {
            let file = claudeHome.appendingPathComponent(".credentials.json")
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                  attributes[.type] as? FileAttributeType == .typeRegular else {
                throw ProviderError.authenticationRequired
            }
            guard let stored = try? Data(contentsOf: file) else { throw ProviderError.permissionDenied }
            data = stored
        }
        struct Payload: Decodable {
            struct OAuth: Decodable {
                let accessToken: String
                let scopes: [String]
                let expiresAt: Double
            }
            let claudeAiOauth: OAuth
        }
        guard let oauth = try? JSONDecoder().decode(Payload.self, from: data).claudeAiOauth,
              !oauth.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              oauth.expiresAt.isFinite, oauth.expiresAt / 1000 > clock.now().timeIntervalSince1970 else {
            throw ProviderError.authenticationRequired
        }
        guard oauth.scopes.contains("user:profile") else { throw ProviderError.permissionDenied }
        return oauth.accessToken
    }

    private static func readKeychain(_ interaction: CredentialInteraction) throws -> Data? {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "Claude Code-credentials",
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        if interaction == .background {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext] = context
        }
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainVault.map(status: status) }
        guard let data = result as? Data else { throw ProviderError.authenticationRequired }
        return data
    }
}
