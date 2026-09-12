import XCTest
import AILimitsCore
@testable import AILimitsMac

/// Task 4, шаг 1: allowlist по точному host И path, не по префиксу.
final class HTTPPolicyTests: XCTestCase {
    private func permits(_ string: String) -> Bool {
        guard let url = URL(string: string) else { return false }
        return EndpointPolicy.permits(provider: .openrouter, url: url)
    }

    func testExactEndpointAllowed() {
        XCTAssertTrue(permits("https://openrouter.ai/api/v1/credits"))
    }

    func testPlainHTTPDenied() {
        XCTAssertFalse(permits("http://openrouter.ai/api/v1/credits"))
    }

    func testLookalikeDomainDenied() {
        XCTAssertFalse(permits("https://openrouter.ai.evil.test/api/v1/credits"))
    }

    func testUserInfoDenied() {
        XCTAssertFalse(permits("https://key@openrouter.ai/api/v1/credits"))
    }

    func testNonStandardPortDenied() {
        XCTAssertFalse(permits("https://openrouter.ai:8443/api/v1/credits"))
    }

    func testQueryOverrideDenied() {
        XCTAssertFalse(permits("https://openrouter.ai/api/v1/credits?x=1"))
    }

    func testOtherPathDenied() {
        // Генерация — не наш путь.
        XCTAssertFalse(permits("https://openrouter.ai/api/v1/chat/completions"))
        // Префиксный трюк /credits/extra тоже не разрешён.
        XCTAssertFalse(permits("https://openrouter.ai/api/v1/credits/extra"))
    }

    func testUnknownHostDenied() {
        XCTAssertFalse(permits("https://example.com/api/v1/credits"))
    }
}
