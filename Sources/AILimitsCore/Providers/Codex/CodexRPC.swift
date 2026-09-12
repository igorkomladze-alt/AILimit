import Foundation

/// Task 11, шаг 4: ограниченная JSONL RPC-поверхность Codex App Server.
/// Только разрешённые методы; генерация, инструменты, кредит-ресеты запрещены.
public enum CodexRPC {
    /// Методы, разрешённые для фонового опроса. Всё остальное — запрет.
    public static let pollAllowedMethods: Set<String> = [
        "initialize", "initialized", "account/read", "account/rateLimits/read"
    ]

    /// Методы, разрешённые только в явном login-flow (инициирован пользователем).
    /// Никогда не используются фоновым опросом (Task 12: poll/login разделены).
    public static let loginAllowedMethods: Set<String> = [
        "account/login/start", "account/login/cancel", "account/logout"
    ]
}

/// Парсер/строитель JSONL-линий App Server (формат R2).
public enum CodexRPCCodec {
    /// Исходящее сообщение без лишнего "jsonrpc" header.
    public static func initialize(id: Int) -> String {
        #"{"method":"initialize","id":\#(id),"params":{"clientInfo":{"name":"ai_limits","title":"AI Limits","version":"0.1.0"}}}"#
    }

    public static func initialized() -> String {
        #"{"method":"initialized","params":{}}"#
    }

    public static func accountRead(id: Int) -> String {
        #"{"method":"account/read","id":\#(id),"params":{"refreshToken":false}}"#
    }

    public static func rateLimitsRead(id: Int) -> String {
        #"{"method":"account/rateLimits/read","id":\#(id)}"#
    }

    /// Запуск входа (только из явного login-flow; тип chatgpt — поддерживаемый вход приложения).
    public static func loginStart(id: Int) -> String {
        #"{"method":"account/login/start","id":\#(id),"params":{"type":"chatgpt"}}"#
    }

    public static func loginCancel(id: Int, loginID: String) -> String {
        #"{"method":"account/login/cancel","id":\#(id),"params":{"loginId":"\#(loginID)"}}"#
    }

    /// Извлечь произвольный result из ответной линии по id (без привязки к rateLimits).
    /// nil — notification или чужой id.
    public static func extractResult(line: Data, expectingID: Int) -> Data? {
        extractRateLimits(line: line, expectingID: expectingID)
    }

    /// Метод notification-линии (без id), например "account/login/completed". nil — не notification.
    public static func notificationMethod(line: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["id"] == nil,
              let method = object["method"] as? String else { return nil }
        return method
    }

    /// id исходящего запроса (для сопоставления ответа). nil — линия без id.
    public static func requestID(line: String) -> Int? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["id"] as? Int
    }

    /// Имя метода исходящей линии (для проверки allowlist до отправки). nil — нет метода.
    public static func methodName(line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["method"] as? String
    }

    /// Извлечь rateLimits-результат из ответной линии по id.
    /// Возвращает nil для разрешённых notifications; ошибка для неожиданного ответа.
    public static func extractRateLimits(line: Data, expectingID: Int) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let methodOrResult = object["id"] as? Int else { return nil }
        guard methodOrResult == expectingID else { return nil }
        guard let result = object["result"] else { return nil }
        return try? JSONSerialization.data(withJSONObject: result)
    }
}
