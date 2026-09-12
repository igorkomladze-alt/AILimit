import Foundation
import AILimitsCore

/// Task 4, шаг 4: типизированный ответ транспорта.
public struct HTTPResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data

    public init(status: Int, headers: [String: String], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

/// Контракт транспорта. Реализация — URLSessionTransport (fail-closed).
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

/// Маппинг HTTP-статусов в типизированные ошибки (план Task 4, шаг 4).
public enum HTTPStatusPolicy {
    /// Retry-After: секунды или HTTP-date; nil — заголовок отсутствует/некорректен.
    public static func retryAfter(headers: [String: String], now: Date) -> Date? {
        guard let raw = headers.first(where: { $0.key.lowercased() == "retry-after" })?.value else {
            return nil
        }
        if let seconds = TimeInterval(raw.trimmingCharacters(in: .whitespaces)), seconds >= 0 {
            return now.addingTimeInterval(seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.date(from: raw)
    }

    public static func error(for status: Int, headers: [String: String], now: Date) -> ProviderError {
        switch status {
        case 401:
            return .authenticationRequired
        case 403:
            // 403 — не «исчерпание подписки», а запрет доступа (например, не Management Key).
            return .permissionDenied
        case 429:
            return .rateLimited(until: retryAfter(headers: headers, now: now) ?? now)
        case 500...599:
            return .server(status: status)
        default:
            return .network
        }
    }
}
