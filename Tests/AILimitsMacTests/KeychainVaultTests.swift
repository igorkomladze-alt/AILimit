import XCTest
import AILimitsCore
@testable import AILimitsMac

/// Task 3, шаг 5: namespace-изоляция и fail-closed поведение Keychain.
/// Используем собственный тестовый namespace через account-префикс, чужие ключи не читаем.
final class KeychainVaultTests: XCTestCase {
    let vault = KeychainVault()

    private func testAccount() -> String {
        "tests:\(UUID().uuidString):key"
    }

    func testIsOwnedServiceNamespace() {
        // Чужие keychain-сервисы не наши.
        XCTAssertFalse(KeychainVault.isOwnedService("Claude Code-credentials"))
        XCTAssertFalse(KeychainVault.isOwnedService("Chrome Safe Storage"))
        XCTAssertTrue(KeychainVault.isOwnedService("local.gutfresh.AILimits"))
    }

    func testSaveReadDeleteRoundTrip() throws {
        let account = testAccount()
        let secret = Data("test-secret-\(account.suffix(8))".utf8)
        try vault.save(secret: secret, account: account)
        let readBack = try vault.read(account: account, interaction: .userInitiated)
        XCTAssertEqual(readBack, secret)
        try vault.delete(account: account)
        // После удаления — itemNotFound → authenticationRequired.
        XCTAssertThrowsError(try vault.read(account: account, interaction: .userInitiated)) { error in
            XCTAssertEqual(error as? ProviderError, .authenticationRequired)
        }
    }

    func testUpdateDoesNotDuplicate() throws {
        let account = testAccount()
        defer { try? vault.delete(account: account) }
        try vault.save(secret: Data("v1".utf8), account: account)
        try vault.save(secret: Data("v2".utf8), account: account)
        let readBack = try vault.read(account: account, interaction: .userInitiated)
        XCTAssertEqual(readBack, Data("v2".utf8))
    }

    func testAccountFormat() {
        let record = ConnectionRecord(
            id: ConnectionID(provider: .openrouter, generation: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!),
            source: .manualKey,
            verifiedIdentityHash: nil
        )
        XCTAssertEqual(
            KeychainVault.account(for: record),
            "openrouter:00000000-0000-0000-0000-000000000001:key"
        )
    }

    /// Ошибка сохранения не должна оставлять статус успеха: read после отказа → ошибка.
    func testFailedReadIsTypedError() {
        let missing = testAccount()
        XCTAssertThrowsError(try vault.read(account: missing, interaction: .background)) { error in
            XCTAssertTrue(error is ProviderError)
        }
    }

    /// Согласие: до grant — consentRequired-семантика на уровне ConsentStore.
    func testConsentStoreGrantRevoke() {
        var consents = ConsentStore()
        XCTAssertFalse(consents.hasConsent(provider: .kimi, sourceDescriptor: "~/.kimi-code"))
        consents.grant(provider: .kimi, sourceDescriptor: "~/.kimi-code", now: Date())
        XCTAssertTrue(consents.hasConsent(provider: .kimi, sourceDescriptor: "~/.kimi-code"))
        // Другой провайдер / другой дескриптор — согласия нет.
        XCTAssertFalse(consents.hasConsent(provider: .claude, sourceDescriptor: "~/.kimi-code"))
        XCTAssertFalse(consents.hasConsent(provider: .kimi, sourceDescriptor: "~/.claude"))
        consents.revoke(provider: .kimi, sourceDescriptor: "~/.kimi-code")
        XCTAssertFalse(consents.hasConsent(provider: .kimi, sourceDescriptor: "~/.kimi-code"))
    }
}
