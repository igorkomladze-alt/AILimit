import XCTest
import AILimitsCore
@testable import AILimitsMac

final class CodexLoginSafetyTests: XCTestCase {
    func testOfficialURLOnly() {
        XCTAssertNotNil(CodexLoginController.safeLoginURL("https://auth.openai.com/oauth/authorize?state=test"))
        for value in ["http://auth.openai.com/a", "https://auth.openai.com.evil.test/", "https://evil.test/", "https://user@auth.openai.com/", "https://auth.openai.com:8443/", "file:///tmp/a"] {
            XCTAssertNil(CodexLoginController.safeLoginURL(value))
        }
    }
    func testFailedAndMalformedCompletionRejected() throws {
        XCTAssertThrowsError(try CodexServerController.validateLoginCompletion(Data(#"{"params":{"success":false}}"#.utf8))) { error in
            XCTAssertEqual(error as? ProviderError, .authenticationRequired)
        }
        XCTAssertThrowsError(try CodexServerController.validateLoginCompletion(Data(#"{"params":{}}"#.utf8)))
        XCTAssertNoThrow(try CodexServerController.validateLoginCompletion(Data(#"{"params":{"success":true}}"#.utf8)))
    }
}


private actor DelayedLoginServer: CodexLoginServing {
    private var continuation: CheckedContinuation<(loginID: String?, url: String, code: String?), Error>?
    func beginLogin() async throws -> (loginID: String?, url: String, code: String?) {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func ready() -> Bool { continuation != nil }
    func finish(failed: Bool) {
        if failed { continuation?.resume(throwing: ProviderError.timeout) }
        else { continuation?.resume(returning: ("fake", "https://auth.openai.com/login", nil)) }
        continuation = nil
    }
    func waitLoginCompleted(timeout: TimeInterval) async throws {}
    func cancelLogin(loginID: String?) async {}
    func logoutOwn() async throws {}
    func stop() async {}
}

extension CodexLoginSafetyTests {
    @MainActor func testCancelledBeginCannotRestoreProgressOrFailure() async throws {
        for failed in [false, true] {
            let server = DelayedLoginServer()
            let controller = CodexLoginController(server: server)
            controller.begin()
            for _ in 0..<100 {
                if await server.ready() { break }
                await Task.yield()
            }
            controller.cancel()
            await server.finish(failed: failed)
            for _ in 0..<20 { await Task.yield() }
            XCTAssertEqual(controller.state, .idle)
        }
    }
}
