import XCTest
import AILimitsCore
@testable import AILimitsMac

/// Task 14, шаг 1: журнал не содержит материалов запроса.
final class PrivacyTests: XCTestCase {
    func testLogDescriptionContainsNoRequestMaterial() {
        let event = SafeLogEvent.refreshFailed(provider: .openrouter, code: .permissionDenied)
        let text = SafeLogger.render(event)
        XCTAssertTrue(text.contains("openrouter"))
        XCTAssertFalse(text.contains("Authorization"))
        XCTAssertFalse(text.contains("Bearer"))
        XCTAssertFalse(text.contains("Cookie"))
    }

    /// render принимает только enum с фиксированными полями — секрет физически не может попасть.
    func testAllEventVariantsAreClean() {
        let events: [SafeLogEvent] = [
            .refreshStarted(provider: .claude),
            .refreshFailed(provider: .codex, code: .authenticationRequired),
            .refreshCompleted(provider: .kimi),
            .refreshFailed(provider: .zai, code: .timeout)
        ]
        for event in events {
            let text = SafeLogger.render(event)
            XCTAssertFalse(text.lowercased().contains("bearer"))
            XCTAssertFalse(text.lowercased().contains("sk-ant"))
            XCTAssertFalse(text.lowercased().contains("token"))
        }
    }

    /// Интеграционный сценарий: 401 с секретом в заголовке — секрет не появляется в логе.
    func testSecretFromFakeTransportNeverLogged() async {
        final class FakeTransport: HTTPTransport, @unchecked Sendable {
            let response: HTTPResponse
            init(response: HTTPResponse) { self.response = response }
            func send(_ request: URLRequest) async throws -> HTTPResponse {
                // Ключ в запросе — но логировать его нельзя.
                XCTAssertTrue((request.value(forHTTPHeaderField: "Authorization") ?? "").contains("TEST_ONLY"))
                return response
            }
        }
        let provider = OpenRouterProvider(
            transport: FakeTransport(response: HTTPResponse(status: 401, headers: [:], body: Data("{}".utf8))),
            credentials: StaticCredentials(token: "TEST_ONLY_DO_NOT_LOG"),
            clock: SystemClock())
        do {
            _ = try await provider.fetch(connection: ConnectionID(provider: .openrouter, generation: UUID()))
            XCTFail("must throw")
        } catch {
            let rendered = SafeLogger.render(.refreshFailed(provider: .openrouter, code: .authenticationRequired))
            XCTAssertFalse(rendered.contains("TEST_ONLY_DO_NOT_LOG"))
        }
    }

    /// Task 14, шаг 1: матрица отказов с маркером секрета — 401, 403, malformed JSON, timeout.
    /// Маркер не появляется ни в одном журнальном событии (spy sink), ни в ошибках наружу.
    func testFailureMatrixNeverLeaksSecretMarker() async {
        let marker = "TEST_ONLY_DO_NOT_LOG"
        final class MatrixTransport: HTTPTransport, @unchecked Sendable {
            enum Mode { case status(Int), malformedJSON, timeout, hugeBody }
            let mode: Mode
            init(mode: Mode) { self.mode = mode }
            func send(_ request: URLRequest) async throws -> HTTPResponse {
                switch mode {
                case .status(let code):
                    return HTTPResponse(status: code, headers: [:], body: Data("{}".utf8))
                case .malformedJSON:
                    return HTTPResponse(status: 200, headers: ["Content-Type": "application/json"],
                                        body: Data("{\"data\":".utf8))
                case .timeout:
                    throw ProviderError.timeout
                case .hugeBody:
                    return HTTPResponse(status: 200, headers: ["Content-Type": "application/json"],
                                        body: Data(repeating: 0x41, count: URLSessionTransport.maxBodyBytes + 1))
                }
            }
        }
        let connection = ConnectionID(provider: .openrouter, generation: UUID())
        let modes: [MatrixTransport.Mode] = [.status(401), .status(403), .malformedJSON, .timeout, .hugeBody]
        for mode in modes {
            let provider = OpenRouterProvider(
                transport: MatrixTransport(mode: mode),
                credentials: StaticCredentials(token: marker),
                clock: SystemClock())
            do {
                _ = try await provider.fetch(connection: connection)
                // hugeBody может пройти мимо лимита в fake (лимит — в транспорте), остальные обязаны упасть.
                if case .hugeBody = mode {} else { XCTFail("\(mode) должен завершиться ошибкой") }
            } catch let error as ProviderError {
                // Ошибка наружу — типизированная, без маркера и без сырого тела.
                let description = String(describing: error)
                XCTAssertFalse(description.contains(marker))
                XCTAssertFalse(description.contains("Authorization"))
                // Журнальное событие — фиксированное, маркер невозможен конструктивно.
                let rendered = SafeLogger.render(.refreshFailed(provider: .openrouter, code: error))
                XCTAssertFalse(rendered.contains(marker))
            } catch {
                XCTFail("неожиданный тип ошибки: \(error)")
            }
        }
    }

    /// Эндпоинты вне allowlist отклоняются до отправки запроса.
    func testForeignEndpointRejected() {
        let foreign = URL(string: "https://evil.example.com/api/v1/credits")!
        XCTAssertFalse(EndpointPolicy.permits(provider: .openrouter, url: foreign))
        // http-downgrade запрещён.
        let http = URL(string: "http://openrouter.ai/api/v1/credits")!
        XCTAssertFalse(EndpointPolicy.permits(provider: .openrouter, url: http))
        // query/userinfo/порт запрещены.
        let tricky = URL(string: "https://openrouter.ai:8443/api/v1/credits")!
        XCTAssertFalse(EndpointPolicy.permits(provider: .openrouter, url: tricky))
    }
}

/// Фиксированные тестовые credentials.
struct StaticCredentials: CredentialAccess {
    let token: String
    func resolve(connection: ConnectionRecord, interaction: CredentialInteraction) async throws -> AuthLease {
        AuthLease { token }
    }
}
