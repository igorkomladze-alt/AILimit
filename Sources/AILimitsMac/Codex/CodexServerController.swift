import Foundation
import AILimitsCore

/// Task 12, шаг 3: разделение методов фонового опроса и явного login-flow.
public enum CodexProcessPolicy {
    /// Методы фонового опроса (чтение, без генераций и инструментов).
    public static let pollMethods = CodexRPC.pollAllowedMethods
    /// Методы login-flow — только в активной сессии входа, инициированной пользователем.
    public static let loginMethods = CodexRPC.loginAllowedMethods
}

/// Task 12: владелец жизненного цикла изолированного Codex app-server.
/// Один процесс на приложение; poll и login используют один транспорт,
/// но login-методы доступны только в активной login-сессии (шаг 4 плана).
public actor CodexServerController: CodexLoginServing {
    public enum ServerError: Error {
        case notLoggedIn
    }

    private let locator: CodexExecutableLocator
    private let home: URL
    private let userHome: URL
    private var transport: CodexProcessTransport?
    private var handshaken = false
    private var nextID = 1
    /// Login-методы разрешены только между beginLogin и cancelLogin/completed.
    private var loginSessionActive = false
    private var loginGeneration = UUID()

    public init(
        locator: CodexExecutableLocator = CodexExecutableLocator(),
        home: URL = CodexLaunchConfiguration.defaultIsolatedHome(),
        userHome: URL = CodexLaunchConfiguration.defaultUserHome()
    ) {
        self.locator = locator
        self.home = home
        self.userHome = userHome
    }

    // MARK: - Жизненный цикл

    /// Поднять app-server, если не запущен. Отсутствие CLI → dependencyMissing (без установки).
    private func ensureTransport() async throws -> CodexProcessTransport {
        if let transport, await transport.isRunning { return transport }
        let executable = try locator.locate()
        let config = CodexLaunchConfiguration(
            executable: executable, home: home, workingDirectory: home)
        try config.validate(userCodexHome: userHome)
        try FileManager.default.createDirectory(
            at: home, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let transport = CodexProcessTransport(configuration: config)
        try await transport.start()
        self.transport = transport
        handshaken = false
        return transport
    }

    private func ensureHandshake() async throws -> CodexProcessTransport {
        let transport = try await ensureTransport()
        if handshaken { return transport }
        _ = try await requestPoll(CodexRPCCodec.initialize(id: nextRequestID()), on: transport)
        try await transport.send(line: CodexRPCCodec.initialized())
        handshaken = true
        return transport
    }

    private func nextRequestID() -> Int {
        defer { nextID += 1 }
        return nextID
    }

    /// Отправить poll-метод: allowlist проверяется ДО записи в stdin.
    private func requestPoll(_ line: String, on transport: CodexProcessTransport? = nil) async throws -> Data {
        guard let method = CodexRPCCodec.methodName(line: line),
              CodexProcessPolicy.pollMethods.contains(method) else {
            throw ProviderError.permissionDenied
        }
        let active: CodexProcessTransport
        if let transport {
            active = transport
        } else {
            active = try await ensureHandshake()
        }
        return try await active.request(line: line)
    }

    // MARK: - Чтение (фоновый опрос)

    /// Вход выполнен? account/read: account != null.
    public func isLoggedIn() async throws -> Bool {
        let result = try await requestPoll(CodexRPCCodec.accountRead(id: nextRequestID()))
        guard let object = try? JSONSerialization.jsonObject(with: result) as? [String: Any] else {
            throw ProviderError.incompatibleSchema
        }
        // account: null — входа нет; requiresOpenaiAuth == true и account null — тоже нет.
        if let account = object["account"], !(account is NSNull) { return true }
        return false
    }

    /// Снимок rate limits. Не вошли → authenticationRequired.
    public func readRateLimits() async throws -> Data {
        guard try await isLoggedIn() else { throw ProviderError.authenticationRequired }
        return try await requestPoll(CodexRPCCodec.rateLimitsRead(id: nextRequestID()))
    }

    // MARK: - Login-flow (только по явному действию пользователя)

    /// Начать вход: возвращает URL для браузера и (если есть) код.
    public func beginLogin() async throws -> (loginID: String?, url: String, code: String?) {
        let attempt = UUID()
        loginGeneration = attempt
        let transport = try await ensureHandshake()
        guard loginGeneration == attempt, !Task.isCancelled else { throw CancellationError() }
        loginSessionActive = true
        do {
            let result = try await requestLogin(CodexRPCCodec.loginStart(id: nextRequestID()), on: transport)
            guard let object = try? JSONSerialization.jsonObject(with: result) as? [String: Any] else {
                throw ProviderError.incompatibleSchema
            }
            let loginID = object["loginId"] as? String
            guard loginGeneration == attempt, !Task.isCancelled else {
                if let loginID {
                    try? await transport.send(line: CodexRPCCodec.loginCancel(id: nextRequestID(), loginID: loginID))
                }
                throw CancellationError()
            }
            let url = (object["authUrl"] as? String)
                ?? (object["url"] as? String)
                ?? (object["verificationUrl"] as? String)
            let code = (object["userCode"] as? String) ?? (object["code"] as? String)
            guard let url, CodexLoginController.safeLoginURL(url) != nil else { throw ProviderError.incompatibleSchema }
            return (loginID, url, code)
        } catch {
            if loginGeneration == attempt { loginSessionActive = false }
            throw error
        }
    }

    /// Ожидание завершения входа (notification account/login/completed). Timeout снаружи.
    public func waitLoginCompleted(timeout: TimeInterval = 300) async throws {
        guard let transport else { throw ProviderError.disconnected }
        let attempt = loginGeneration
        defer { if loginGeneration == attempt { loginSessionActive = false } }
        let notification = try await transport.waitNotification(method: "account/login/completed", timeout: timeout)
        try Self.validateLoginCompletion(notification)
    }

    nonisolated static func validateLoginCompletion(_ data: Data) throws {
        struct Notification: Decodable {
            struct Params: Decodable { let success: Bool }
            let params: Params
        }
        guard let notification = try? JSONDecoder().decode(Notification.self, from: data) else {
            throw ProviderError.incompatibleSchema
        }
        guard notification.params.success else { throw ProviderError.authenticationRequired }
    }

    /// Отмена входа по явному действию пользователя.
    public func cancelLogin(loginID: String?) async {
        loginGeneration = UUID()
        guard loginSessionActive, let transport else { return }
        if let loginID {
            try? await transport.send(line: CodexRPCCodec.loginCancel(id: nextRequestID(), loginID: loginID))
        }
        loginSessionActive = false
    }

    /// Logout ТОЛЬКО собственного изолированного входа (при отключении в UI).
    public func logoutOwn() async throws {
        loginSessionActive = true
        defer { loginSessionActive = false }
        guard let transport = try? await ensureHandshake() else { return }
        _ = try? await transport.request(
            line: #"{"method":"account/logout","id":\#(nextRequestID())}"#)
    }

    private func requestLogin(_ line: String, on transport: CodexProcessTransport) async throws -> Data {
        guard loginSessionActive,
              let method = CodexRPCCodec.methodName(line: line),
              CodexProcessPolicy.loginMethods.contains(method) else {
            throw ProviderError.permissionDenied
        }
        return try await transport.request(line: line)
    }

    /// Остановка helper (сон приложения/выход). Только собственный child.
    public func stop() async {
        loginGeneration = UUID()
        await transport?.stop()
        transport = nil
        handshaken = false
        loginSessionActive = false
    }
}
