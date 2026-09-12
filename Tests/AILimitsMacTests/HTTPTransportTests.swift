import XCTest
import Foundation
@testable import AILimitsMac
import AILimitsCore

final class HTTPTransportTests: XCTestCase {
    private func transport() -> URLSessionTransport {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BoundedResponseProtocol.self]
        return URLSessionTransport(session: URLSession(configuration: config))
    }

    func testRejectsOversizedDeclaredLengthBeforeFullBody() async {
        await assertError(path: "declared", expected: .invalidData)
    }

    func testRejectsOversizedStreamWithoutWaitingForEnd() async {
        await assertError(path: "stream", expected: .invalidData)
    }

    func testMapsTimeout() async {
        await assertError(path: "timeout", expected: .timeout)
    }

    func testMapsOffline() async {
        await assertError(path: "offline", expected: .network)
    }

    func testReadsSmallBody() async throws {
        let response = try await transport().send(URLRequest(url: URL(string: "https://example.invalid/small")!))
        XCTAssertEqual(response.body, Data("ok".utf8))
    }

    private func assertError(path: String, expected: ProviderError) async {
        do {
            _ = try await transport().send(URLRequest(url: URL(string: "https://example.invalid/\(path)")!))
            XCTFail("Expected failure")
        } catch {
            XCTAssertEqual(error as? ProviderError, expected)
        }
    }
}

/// Oversized responses deliberately never finish successfully: consuming the entire
/// response ends in timeout, whereas bounded readers reject before that terminal error.
private final class BoundedResponseProtocol: URLProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { lock.lock(); stopped = true; lock.unlock() }
    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    override func startLoading() {
        let path = request.url!.lastPathComponent
        if path == "timeout" || path == "offline" {
            client?.urlProtocol(self, didFailWithError: URLError(path == "timeout" ? .timedOut : .notConnectedToInternet))
            return
        }
        let headers = path == "declared" ? ["Content-Length": "\(URLSessionTransport.maxBodyBytes + 1)"] : [:]
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        if path == "small" {
            client?.urlProtocol(self, didLoad: Data("ok".utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        // Foundation's AsyncBytes publishes a URLProtocol response with the first
        // body buffer. A partial chunk is supplied; no full response is produced.
        if path == "declared" { client?.urlProtocol(self, didLoad: Data(repeating: 65, count: 65536)) }
        if path == "stream" { sendChunk(remaining: 33) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
            if !isStopped { client?.urlProtocol(self, didFailWithError: URLError(.timedOut)) }
        }
    }

    private func sendChunk(remaining: Int) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.005) { [self] in
            guard !isStopped, remaining > 0 else { return }
            client?.urlProtocol(self, didLoad: Data(repeating: 65, count: 65536))
            sendChunk(remaining: remaining - 1)
        }
    }
}
