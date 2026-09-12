import XCTest
import AILimitsCore
@testable import AILimitsMac

/// Task 8, шаг 5: read-only контракт Kimi credential reader.
final class KimiCredentialReaderTests: XCTestCase {
    private var fakeHome: URL!

    override func setUpWithError() throws {
        fakeHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("kimi-fake-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fakeHome)
    }

    private func writeCredentials(_ json: String) throws {
        try FileManager.default.createDirectory(
            at: fakeHome.appendingPathComponent("credentials"), withIntermediateDirectories: true)
        try json.write(to: fakeHome.appendingPathComponent("credentials/kimi-code.json"),
                       atomically: true, encoding: .utf8)
    }

    private func snapshot() throws -> [String: (Data, Date)] {
        var result: [String: (Data, Date)] = [:]
        let enumerator = FileManager.default.enumerator(at: fakeHome, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue
            else { continue } // каталоги пропускаем — читаем только файлы
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? Date()
            result[url.lastPathComponent] = (try Data(contentsOf: url), mtime)
        }
        return result
    }

    private func record(_ source: CredentialSource) -> ConnectionRecord {
        ConnectionRecord(
            id: ConnectionID(provider: .kimi, generation: UUID()),
            source: source,
            verifiedIdentityHash: nil
        )
    }

    func testReadsAccessToken() async throws {
        try writeCredentials(#"{"access_token":"kimi-at-123","refresh_token":"kimi-rt-secret","device_id":"dev"}"#)
        let reader = KimiCredentialReader(kimiHome: fakeHome)
        let lease = try await reader.resolve(connection: record(.kimiCLI), interaction: .background)
        XCTAssertEqual(lease.authorizer(), "kimi-at-123")
    }

    /// Файлы чужого CLI остаются побайтно неизменными, включая mtime.
    func testFakeHomeUnchangedAfterRead() async throws {
        try writeCredentials(#"{"access_token":"kimi-at-123","refresh_token":"rt"}"#)
        let before = try snapshot()
        let reader = KimiCredentialReader(kimiHome: fakeHome)
        _ = try await reader.resolve(connection: record(.kimiCLI), interaction: .background)
        let after = try snapshot()
        XCTAssertEqual(before.keys, after.keys)
        for (name, (data, mtime)) in before {
            XCTAssertEqual(data, after[name]?.0, "содержимое \(name) изменилось")
            XCTAssertEqual(mtime.timeIntervalSince1970,
                           after[name]?.1.timeIntervalSince1970 ?? -1, accuracy: 0.001,
                           "mtime \(name) изменилось")
        }
    }

    /// Отсутствующий файл → authenticationRequired (UI предлагает ключ), без создания файла.
    func testMissingFileYieldsAuthRequiredAndCreatesNothing() async throws {
        let reader = KimiCredentialReader(kimiHome: fakeHome)
        do {
            _ = try await reader.resolve(connection: record(.kimiCLI), interaction: .background)
            XCTFail("must throw")
        } catch {
            XCTAssertEqual(error as? ProviderError, .authenticationRequired)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fakeHome.path),
                       "reader не должен создавать ~/.kimi-code")
    }

    /// Некорректный JSON → authenticationRequired, файл не тронут.
    func testCorruptedCredentialsYieldAuthRequired() async throws {
        try writeCredentials("{corrupted")
        let before = try Data(contentsOf: fakeHome.appendingPathComponent("credentials/kimi-code.json"))
        let reader = KimiCredentialReader(kimiHome: fakeHome)
        do {
            _ = try await reader.resolve(connection: record(.kimiCLI), interaction: .background)
            XCTFail("must throw")
        } catch {
            XCTAssertEqual(error as? ProviderError, .authenticationRequired)
        }
        let after = try Data(contentsOf: fakeHome.appendingPathComponent("credentials/kimi-code.json"))
        XCTAssertEqual(before, after)
    }

    private struct FakeVault: CredentialAccess {
        let missing: Bool
        func resolve(connection: ConnectionRecord, interaction: CredentialInteraction) async throws -> AuthLease {
            XCTAssertEqual(connection.source, .manualKey)
            if missing { throw ProviderError.authenticationRequired }
            return AuthLease { "manual-test-key" }
        }
    }

    func testManualKeyUsesInjectedVaultEvenWithCLIPresent() async throws {
        try writeCredentials(#"{"access_token":"cli-test-key"}"#)
        let reader = KimiCredentialReader(kimiHome: fakeHome, vault: FakeVault(missing: false))
        let lease = try await reader.resolve(connection: record(.manualKey), interaction: .background)
        XCTAssertEqual(lease.authorizer(), "manual-test-key")
    }

    func testMissingManualKeyDoesNotFallbackToCLI() async throws {
        try writeCredentials(#"{"access_token":"cli-test-key"}"#)
        let reader = KimiCredentialReader(kimiHome: fakeHome, vault: FakeVault(missing: true))
        do {
            _ = try await reader.resolve(connection: record(.manualKey), interaction: .background)
            XCTFail("Missing manual key must fail")
        } catch { XCTAssertEqual(error as? ProviderError, .authenticationRequired) }
    }
}
