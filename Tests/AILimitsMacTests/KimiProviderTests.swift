import XCTest
import AILimitsCore
@testable import AILimitsMac

final class KimiProviderTests: XCTestCase {
    actor Credentials: CredentialAccess {
        var records: [ConnectionRecord] = []
        func resolve(connection: ConnectionRecord, interaction: CredentialInteraction) async throws -> AuthLease {
            records.append(connection)
            throw ProviderError.consentRequired
        }
        func seen() -> [ConnectionRecord] { records }
    }
    struct NeverTransport: HTTPTransport {
        func send(_ request: URLRequest) async throws -> HTTPResponse {
            XCTFail("No request expected")
            throw ProviderError.invalidData
        }
    }
    func testResolvesSavedSourceWithoutFallback() async {
        for source: CredentialSource in [.manualKey, .kimiCLI] {
            let id = ConnectionID(provider: .kimi, generation: UUID())
            let record = ConnectionRecord(id: id, source: source, verifiedIdentityHash: nil)
            let credentials = Credentials()
            let provider = KimiProvider(transport: NeverTransport(), credentials: credentials, recordResolver: { _ in record })
            do { _ = try await provider.fetch(connection: id); XCTFail() }
            catch { XCTAssertEqual(error as? ProviderError, .consentRequired) }
            let seen = await credentials.seen()
            XCTAssertEqual(seen, [record])
        }
    }
    func testRetiredGenerationAndMissingRecordNeverResolveCredentials() async {
        let id = ConnectionID(provider: .kimi, generation: UUID())
        let newer = ConnectionRecord(id: ConnectionID(provider: .kimi, generation: UUID()), source: .manualKey, verifiedIdentityHash: nil)
        for record in [nil, newer] {
            let credentials = Credentials()
            let provider = KimiProvider(transport: NeverTransport(), credentials: credentials, recordResolver: { _ in record })
            do { _ = try await provider.fetch(connection: id); XCTFail() }
            catch { XCTAssertEqual(error as? ProviderError, .disconnected) }
            let seen = await credentials.seen()
            XCTAssertTrue(seen.isEmpty)
        }
    }
}
