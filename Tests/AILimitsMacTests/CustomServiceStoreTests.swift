import XCTest
import Foundation
@testable import AILimitsMac
import AILimitsCore

private actor CustomStubTransport: HTTPTransport {
    var response = HTTPResponse(status: 200, headers: [:], body: Data("{\"balance\":12.50}".utf8))
    var requests: [URLRequest] = []
    var suspended = false
    var pending: CheckedContinuation<Void, Never>?
    func suspendNext() { suspended = true }
    func resume() { pending?.resume(); pending = nil }
    func hasPending() -> Bool { pending != nil }
    func set(status: Int, headers: [String:String] = [:], body: String = "{}") { response = .init(status: status, headers: headers, body: Data(body.utf8)) }
    func send(_ request: URLRequest) async throws -> HTTPResponse { requests.append(request); if suspended { suspended = false; await withCheckedContinuation { pending = $0 } }; return response }
    func count() -> Int { requests.count }
    func lastKey() -> String? { requests.last?.value(forHTTPHeaderField: "Authorization") }
}
private final class CustomTestVault: SecretVault, @unchecked Sendable {
    private let lock = NSLock()
    private var data: [String:Data] = [:]
    func save(secret: Data, account: String) throws { lock.withLock { data[account] = secret } }
    func delete(account: String) throws { lock.withLock { data[account] = nil } }
    func read(_ account: String) throws -> Data { try lock.withLock { guard let value = data[account] else { throw CustomServiceError.invalid("Нет ключа") }; return value } }
    func accounts() -> [String] { lock.withLock { Array(data.keys) } }
    func resolve(connection: ConnectionRecord, interaction: CredentialInteraction) async throws -> AuthLease { AuthLease { nil } }
}
@MainActor final class CustomServiceStoreTests: XCTestCase {
    func definition() -> CustomServiceDefinition { .init(name: "Custom", endpoint: URL(string: "https://example.com/usage")!, auth: .bearer, metrics: [.init(name: "Balance", valuePath: "balance", kind: .balance)]) }
    func testSaveReloadBlankEditAndDeleteKeepSecretOutOfJSON() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = CustomStubTransport(), vault = CustomTestVault()
        let store = CustomServiceStore(directory: directory, transport: transport, vault: vault, readSecret: { try vault.read($0) })
        var definition = definition()
        try await store.save(definition: definition, key: "TEST_SECRET_123")
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(vault.accounts().count, 1)
        XCTAssertTrue(vault.accounts()[0].hasPrefix("custom:"))
        let json = try String(contentsOf: directory.appendingPathComponent("custom-services.json"), encoding: .utf8)
        XCTAssertFalse(json.contains("TEST_SECRET_123"))
        definition.name = "Edited"
        try await store.save(definition: definition, key: "")
        let key = await transport.lastKey(); XCTAssertEqual(key, "Bearer TEST_SECRET_123")
        XCTAssertEqual(vault.accounts().count, 1)
        let reload = CustomServiceStore(directory: directory, transport: transport, vault: vault, readSecret: { try vault.read($0) })
        XCTAssertEqual(reload.entries[0].definition.name, "Edited")
        XCTAssertEqual(reload.entries[0].snapshot?.metrics[0].value, Decimal(string:"12.5"))
        try reload.delete(id: definition.id)
        XCTAssertTrue(reload.entries.isEmpty); XCTAssertTrue(vault.accounts().isEmpty)
    }
    func testFailedEditPreservesSavedDefinitionAndCredential() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = CustomStubTransport(), vault = CustomTestVault()
        let store = CustomServiceStore(directory: directory, transport: transport, vault: vault, readSecret: { try vault.read($0) })
        var definition = definition()
        try await store.save(definition: definition, key: "old")
        let accounts = vault.accounts()
        await transport.set(status: 401, body: "SECRET")
        definition.name = "Failed"
        do { try await store.save(definition: definition, key: "new"); XCTFail("Expected error") } catch { XCTAssertFalse(error.localizedDescription.contains("SECRET")) }
        XCTAssertEqual(store.entries[0].definition.name, "Custom"); XCTAssertEqual(vault.accounts(), accounts)
    }
    func testRetryAfterHonoredOnManualRefresh() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = CustomStubTransport(), vault = CustomTestVault()
        let store = CustomServiceStore(directory: directory, transport: transport, vault: vault, readSecret: { try vault.read($0) })
        try await store.save(definition: definition(), key: "key")
        await transport.set(status:429, headers:["Retry-After":"3600"])
        await store.refreshAll(force:true)
        await store.refreshAll(force:true)
        let count = await transport.count(); XCTAssertEqual(count,2)
        XCTAssertNotNil(store.entries[0].error); XCTAssertNotNil(store.entries[0].snapshot)
    }
    func testDeletedServiceCannotReturnAfterSuspendedRefresh() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = CustomStubTransport(), vault = CustomTestVault()
        let store = CustomServiceStore(directory: directory, transport: transport, vault: vault, readSecret: { try vault.read($0) })
        let definition = definition()
        try await store.save(definition: definition, key: "key")
        await transport.suspendNext()
        let refresh = Task { await store.refreshAll(force:true) }
        while !(await transport.hasPending()) { await Task.yield() }
        try store.delete(id: definition.id)
        await transport.resume(); await refresh.value
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(vault.accounts().isEmpty)
    }
    func testCancelledSaveDoesNotPersistOrWriteSecret() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = CustomStubTransport(), vault = CustomTestVault()
        let store = CustomServiceStore(directory: directory, transport: transport, vault: vault, readSecret: { try vault.read($0) })
        let definition = definition()
        await transport.suspendNext()
        let save = Task { try await store.save(definition: definition, key: "key") }
        while !(await transport.hasPending()) { await Task.yield() }
        save.cancel(); await transport.resume()
        do { try await save.value; XCTFail("Expected cancellation") } catch {}
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(vault.accounts().isEmpty)
    }

}
