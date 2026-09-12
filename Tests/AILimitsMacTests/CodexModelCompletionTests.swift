import XCTest
import AILimitsCore
@testable import AILimitsMac

private actor CompletedServer: CodexLoginServing {
    func beginLogin() async throws -> (loginID: String?, url: String, code: String?) { ("test", "https://auth.openai.com/login", nil) }
    func waitLoginCompleted(timeout: TimeInterval) async throws {}
    func cancelLogin(loginID: String?) async {}
    func logoutOwn() async throws {}
    func stop() async {}
}

@MainActor final class CodexModelCompletionTests: XCTestCase {
    func testCompletionRegistersWithoutAnyViewAndKeepsGeneration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let login = CodexLoginController(server: CompletedServer())
        let model = AppModel(
            stateFile: AtomicStateFile(directory: directory), alertFile: AlertStateFile(alertsIn: directory),
            notifications: AppModelPersistenceTests.FakeNotifications(), systemEvents: SystemEvents(),
            codexServer: CodexServerController(locator: CodexExecutableLocator(candidates: [])),
            codexLogin: login,
            vault: AppModelPersistenceTests.FakeVault(),
            providers: [.openrouter: AppModelPersistenceTests.FakeOpenRouter(balance: 0)])
        login.begin()
        for _ in 0..<100 {
            if model.cards.first(where: { $0.provider == .codex })?.connection != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let initial = model.cards.first(where: { $0.provider == .codex })?.connection
        XCTAssertNotNil(initial)
        login.begin()
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(model.cards.first(where: { $0.provider == .codex })?.connection, initial)
    }
}
