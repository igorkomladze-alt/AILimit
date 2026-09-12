import Foundation
import AILimitsCore

/// Task 4, шаг 4: URLSession-транспорт с жёсткими границами.
/// - ephemeral, без cookies и кэша
/// - не следует redirect (Authorization не уйдёт на чужой домен)
/// - тело ограничено 2 MiB ВО ВРЕМЯ чтения
/// - timeout 30 с (request и resource)
public struct URLSessionTransport: HTTPTransport {
    /// Лимит тела ответа: 2 MiB.
    public static let maxBodyBytes = 2 * 1024 * 1024

    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 30
        let delegate = RedirectBlockingDelegate()
        self.session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    /// Инъекция сессии для тестов.
    init(session: URLSession) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        var data = Data()
        let response: URLResponse
        do {
            let (bytes, receivedResponse) = try await session.bytes(for: request)
            response = receivedResponse
            // Stop the underlying task on every exit, including early rejection and
            // caller cancellation. Never wait for an oversized response to finish.
            defer { bytes.task.cancel() }
            let declaredLength = (response as? HTTPURLResponse)?
                .value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init)
            guard response.expectedContentLength <= Int64(Self.maxBodyBytes),
                  declaredLength.map({ $0 <= Int64(Self.maxBodyBytes) }) ?? true else {
                throw ProviderError.invalidData
            }
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < Self.maxBodyBytes else { throw ProviderError.invalidData }
                data.append(byte)
            }
        } catch is CancellationError {
            throw ProviderError.cancelled
        } catch let error as URLError {
            switch error.code {
            case .timedOut:
                throw ProviderError.timeout
            case .cancelled:
                throw ProviderError.cancelled
            default:
                throw ProviderError.network
            }
        }
        guard let http = response as? HTTPURLResponse else { throw ProviderError.network }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let k = key as? String, let v = value as? String { headers[k] = v }
        }
        return HTTPResponse(status: http.statusCode, headers: headers, body: data)
    }
}

/// Отклонение любых redirect: nil в delegate отменяет переход, Authorization не переотправляется.
private final class RedirectBlockingDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
