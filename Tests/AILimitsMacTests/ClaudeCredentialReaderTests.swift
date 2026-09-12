import XCTest
import AILimitsCore
@testable import AILimitsMac

final class ClaudeCredentialReaderTests: XCTestCase {
    private let valid = Data(#"{"claudeAiOauth":{"accessToken":"synthetic","scopes":["user:profile"],"expiresAt":4102444800000}}"#.utf8)
    func testCamelCaseKeychainRecord() throws {
        let data = valid
        let reader = ClaudeCredentialReader(keychainRead: { interaction in
            XCTAssertEqual(interaction, .background)
            return data
        })
        XCTAssertEqual(try reader.readForTest(interaction: .background), "synthetic")
    }
    func testScopeAndExpiryFailClosed() throws {
        for json in [
            #"{"claudeAiOauth":{"accessToken":"x","scopes":["not-user:profile"],"expiresAt":4102444800000}}"#,
            #"{"claudeAiOauth":{"accessToken":"x","scopes":["user:profile"],"expiresAt":1}}"#,
            #"{"claudeAiOauth":{"accessToken":"x","scopes":["user:profile"]}}"#,
            #"{"mcpOAuth":{}}"#] {
            let reader = ClaudeCredentialReader(keychainRead: { _ in Data(json.utf8) })
            XCTAssertThrowsError(try reader.readForTest(interaction: .background))
        }
    }
    func testFileFallbackOnlyWhenKeychainMissingAndFileUnchanged() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent(".credentials.json")
        try valid.write(to: file)
        let reader = ClaudeCredentialReader(claudeHome: home, keychainRead: { _ in nil })
        XCTAssertEqual(try reader.readForTest(interaction: .userInitiated), "synthetic")
        let locked = ClaudeCredentialReader(claudeHome: home, keychainRead: { _ in throw ProviderError.keychainLocked })
        XCTAssertThrowsError(try locked.readForTest(interaction: .background)) { error in
            XCTAssertEqual(error as? ProviderError, .keychainLocked)
        }
        XCTAssertEqual(try Data(contentsOf: file), valid)
    }
}
