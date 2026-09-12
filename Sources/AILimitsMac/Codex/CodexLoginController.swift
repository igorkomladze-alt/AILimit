import Foundation
import AILimitsCore

public protocol CodexLoginServing: Sendable {
    func beginLogin() async throws -> (loginID: String?, url: String, code: String?)
    func waitLoginCompleted(timeout: TimeInterval) async throws
    func cancelLogin(loginID: String?) async
    func logoutOwn() async throws
    func stop() async
}

/// Task 12, шаг 4/5: login-flow Codex (только по явному действию пользователя).
/// Показывает официальный URL/code из ответа app-server и ждёт login/completed.
/// Чужой вход не затрагивается: процесс работает с изолированным CODEX_HOME.
@MainActor
public final class CodexLoginController: ObservableObject {
    public enum State: Equatable, Sendable {
        case idle
        case inProgress(url: String, code: String?)
        case completed
        case failed(String)
    }

    @Published public private(set) var state: State = .idle

    private let server: any CodexLoginServing
    private var generation = UUID()
    private var loginID: String?
    private var waitTask: Task<Void, Never>?

    public init(server: any CodexLoginServing) {
        self.server = server
    }

    /// Начать вход. URL/code показываются пользователю; браузер открывает сам пользователь
    /// (приложение не открывает URL автоматически — источник URL не доверенный ответ сети,
    /// но это официальный flow, полученный от локального CLI, не из сети приложения).
    nonisolated public static func safeLoginURL(_ value: String) -> URL? {
        guard let parts = URLComponents(string: value),
              parts.scheme?.lowercased() == "https",
              parts.host?.lowercased() == "auth.openai.com",
              parts.user == nil, parts.password == nil,
              parts.port == nil || parts.port == 443 else { return nil }
        return parts.url
    }

    public func begin() {
        if case .inProgress = state { return }
        let attempt = UUID()
        generation = attempt
        state = .inProgress(url: "", code: nil)
        waitTask = Task { [weak self] in
            guard let self else { return }
            do {
                let login = try await self.server.beginLogin()
                guard self.generation == attempt, !Task.isCancelled else { return }
                await MainActor.run {
                    self.loginID = login.loginID
                    self.state = .inProgress(url: login.url, code: login.code)
                }
                try await self.server.waitLoginCompleted(timeout: 600)
                guard self.generation == attempt, !Task.isCancelled else { return }
                await MainActor.run { self.state = .completed }
            } catch is CancellationError {
                // Отмена — тихий выход.
            } catch let error as ProviderError {
                guard self.generation == attempt, !Task.isCancelled else { return }
                await MainActor.run { self.state = .failed(Self.describe(error)) }
            } catch {
                guard self.generation == attempt, !Task.isCancelled else { return }
                await MainActor.run { self.state = .failed("Ошибка входа") }
            }
        }
    }

    public func cancel() {
        generation = UUID()
        waitTask?.cancel()
        waitTask = nil
        let id = loginID
        loginID = nil
        state = .idle
        Task { await server.cancelLogin(loginID: id) }
    }

    /// Отключение: logout собственного изолированного входа и остановка helper.
    public func disconnect() async {
        cancel()
        try? await server.logoutOwn()
        await server.stop()
    }

    static func describe(_ error: ProviderError) -> String {
        switch error {
        case .dependencyMissing: return "Codex CLI не найден (установите официальный CLI)"
        case .authenticationRequired: return "Вход не выполнен"
        case .timeout: return "Время ожидания входа истекло"
        case .incompatibleSchema: return "Версия Codex CLI не поддерживается"
        default: return "Ошибка входа"
        }
    }
}
