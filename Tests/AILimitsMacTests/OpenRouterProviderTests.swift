import XCTest
import AILimitsCore
@testable import AILimitsMac

/// Task 4, шаг 6: поведение провайдера на границах транспорта. Секреты не утекают.
final class OpenRouterProviderTests: XCTestCase {
    /// Подменный транспорт: возвращает заготовленный ответ, фиксирует запросы.
    final class FakeTransport: HTTPTransport, @unchecked Sendable {
        var lastRequest: URLRequest?
        var result: Result<HTTPResponse, ProviderError>

        init(result: Result<HTTPResponse, ProviderError>) {
            self.result = result
        }

        func send(_ request: URLRequest) async throws -> HTTPResponse {
            lastRequest = request
            return try result.get()
        }
    }

    /// Учётные, которые всегда дают тестовый ключ.
    struct FakeCredentials: CredentialAccess {
        func resolve(connection: ConnectionRecord, interaction: CredentialInteraction) async throws -> AuthLease {
            AuthLease { "TEST_ONLY_DO_NOT_LOG" }
        }
    }

    struct ThrowingCredentials: CredentialAccess {
        func resolve(connection: ConnectionRecord, interaction: CredentialInteraction) async throws -> AuthLease {
            throw ProviderError.consentRequired
        }
    }

    private func makeProvider(transport: FakeTransport) -> OpenRouterProvider {
        OpenRouterProvider(transport: transport, credentials: FakeCredentials(), clock: MockClock())
    }

    private func connection() -> ConnectionID {
        ConnectionID(provider: .openrouter, generation: UUID())
    }

    func testSuccessfulFetchReturnsBalance() async throws {
        let body = Data(#"{"data":{"total_credits":10,"total_usage":4}}"#.utf8)
        let transport = FakeTransport(result: .success(HTTPResponse(
            status: 200, headers: ["Content-Type": "application/json"], body: body)))
        let provider = makeProvider(transport: transport)

        let snapshot = try await provider.fetch(connection: connection())
        XCTAssertEqual(snapshot.balanceUSD, 6)
        XCTAssertEqual(snapshot.source, "openrouter.credits.v1")
        // Authorization ушёл на разрешённый endpoint.
        XCTAssertEqual(transport.lastRequest?.url?.absoluteString, "https://openrouter.ai/api/v1/credits")
    }

    /// 401 → authenticationRequired; секрет в ошибке не появляется (ошибка типизированная).
    func test401MapsToAuthenticationRequired() async {
        let transport = FakeTransport(result: .success(HTTPResponse(
            status: 401, headers: [:], body: Data("{}".utf8))))
        let provider = makeProvider(transport: transport)
        do {
            _ = try await provider.fetch(connection: connection())
            XCTFail("must throw")
        } catch {
            XCTAssertEqual(error as? ProviderError, .authenticationRequired)
        }
    }

    func test403MapsToPermissionDenied() async {
        let transport = FakeTransport(result: .success(HTTPResponse(
            status: 403, headers: [:], body: Data())))
        let provider = makeProvider(transport: transport)
        do {
            _ = try await provider.fetch(connection: connection())
            XCTFail("must throw")
        } catch {
            XCTAssertEqual(error as? ProviderError, .permissionDenied)
        }
    }

    func test429MapsToRateLimitedWithRetryAfter() async {
        let clock = MockClock()
        let transport = FakeTransport(result: .success(HTTPResponse(
            status: 429, headers: ["Retry-After": "120"], body: Data())))
        let provider = OpenRouterProvider(transport: transport, credentials: FakeCredentials(), clock: clock)
        do {
            _ = try await provider.fetch(connection: connection())
            XCTFail("must throw")
        } catch {
            guard case .rateLimited(let until) = error as? ProviderError else {
                return XCTFail("expected rateLimited")
            }
            // until = clock.now() + 120 с (подменяемые часы, детерминированно).
            XCTAssertEqual(until, clock.now().addingTimeInterval(120))
        }
    }

    /// HTTP 200 с HTML отклоняется: incompatibleSchema.
    func testHTMLWith200Rejected() async {
        let transport = FakeTransport(result: .success(HTTPResponse(
            status: 200, headers: ["Content-Type": "text/html"], body: Data("<html></html>".utf8))))
        let provider = makeProvider(transport: transport)
        do {
            _ = try await provider.fetch(connection: connection())
            XCTFail("must throw")
        } catch {
            XCTAssertEqual(error as? ProviderError, .incompatibleSchema)
        }
    }

    /// Согласие не дано: consentRequired до любых сетевых вызовов.
    func testNoConsentNoNetwork() async {
        let transport = FakeTransport(result: .success(HTTPResponse(status: 200, headers: [:], body: Data())))
        let provider = OpenRouterProvider(transport: transport, credentials: ThrowingCredentials(), clock: MockClock())
        do {
            _ = try await provider.fetch(connection: connection())
            XCTFail("must throw")
        } catch {
            XCTAssertEqual(error as? ProviderError, .consentRequired)
            XCTAssertNil(transport.lastRequest, "сеть не должна вызываться до согласия")
        }
    }
}
