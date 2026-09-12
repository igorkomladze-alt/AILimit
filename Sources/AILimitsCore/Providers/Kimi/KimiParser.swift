import Foundation

/// Task 8, шаг 3: парсер Kimi Code usages (R5).
/// usage — основной счётчик подписки; limits[] — отдельные timed-окна.
/// Числа — JSON numbers или строки строго JSON-number grammar → Decimal без Double.
public enum KimiParser {
    /// Полный match JSON-number grammar: "-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?".
    private static let numberRegex = try! NSRegularExpression(
        pattern: "^-?(0|[1-9][0-9]*)(\\.[0-9]+)?([eE][+-]?[0-9]+)?$")

    static func parseDecimal(_ raw: String) -> Decimal? {
        guard numberRegex.firstMatch(
            in: raw, range: NSRange(raw.startIndex..., in: raw)) != nil else { return nil }
        return Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX"))
    }

    private struct UsageEnvelope: Decodable {
        struct Usage: Decodable {
            let limit: FlexibleNumber?
            let used: FlexibleNumber?
            let remaining: FlexibleNumber?
            let resetTime: String?
        }
        struct Window: Decodable {
            let duration: Int?
            let timeUnit: String?
        }
        struct Limit: Decodable {
            let window: Window?
            let detail: Detail?
        }
        struct Detail: Decodable {
            let limit: FlexibleNumber?
            let used: FlexibleNumber?
            let remaining: FlexibleNumber?
        }
        let usage: Usage?
        let limits: [Limit]?
    }

    /// Строка или число → Decimal. Строка обязана быть JSON-number целиком.
    enum FlexibleNumber: Decodable {
        case decimal(Decimal)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let raw = try? container.decode(String.self) {
                guard let value = KimiParser.parseDecimal(raw) else {
                    throw DecodingError.dataCorruptedError(
                        in: container, debugDescription: "not a JSON-number string: \(raw)")
                }
                self = .decimal(value)
            } else if let value = try? container.decode(Decimal.self) {
                self = .decimal(value)
            } else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a number")
            }
        }

        var value: Decimal? {
            if case .decimal(let d) = self { return d }
            return nil
        }
    }

    private static func secondsPerUnit(_ unit: String?) -> TimeInterval? {
        switch unit {
        case "TIME_UNIT_SECOND": return 1
        case "TIME_UNIT_MINUTE": return 60
        case "TIME_UNIT_HOUR": return 3600
        case "TIME_UNIT_DAY": return 86400
        default: return nil // неизвестный unit → длительность недоступна, не выдумываем
        }
    }

    private static func iso8601Flexible(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    /// Основной счётчик → квота; detail → remaining/limit → процент.
    private static func makeQuota(
        id: String, title: String, limit: Decimal?, used: Decimal?,
        remaining: Decimal?, windowSeconds: TimeInterval?, resetTime: Date?
    ) -> UsageQuota {
        // remaining отсутствует → limit − used (если оба валидны).
        var remainingValue = remaining
        if remainingValue == nil, let limit, let used {
            remainingValue = limit - used
        }
        let value: QuotaValue
        if let limit, let remainingValue, limit > 0, remainingValue >= 0, remainingValue <= limit {
            value = .counts(remaining: remainingValue, total: limit, unit: "requests")
        } else if limit != nil || used != nil || remaining != nil {
            value = .unknown // противоречивые счётчики — не маскировать
        } else {
            value = .unknown
        }
        return UsageQuota(
            id: id, title: title, value: value,
            windowSeconds: windowSeconds, resetsAt: resetTime
        )
    }

    public static func quotas(from data: Data) throws -> [UsageQuota] {
        let envelope: UsageEnvelope
        do {
            envelope = try JSONDecoder().decode(UsageEnvelope.self, from: data)
        } catch {
            throw ProviderError.invalidData
        }
        guard envelope.usage != nil || envelope.limits != nil else {
            throw ProviderError.invalidData
        }

        var quotas: [UsageQuota] = []
        if let usage = envelope.usage {
            quotas.append(makeQuota(
                id: "kimi.code.main",
                title: "Основная квота",
                limit: usage.limit?.value,
                used: usage.used?.value,
                remaining: usage.remaining?.value,
                windowSeconds: nil, // подписка: длительность источником не подтверждена
                resetTime: usage.resetTime.flatMap(iso8601Flexible)
            ))
        }
        if let limits = envelope.limits {
            for (index, limit) in limits.enumerated() {
                guard let detail = limit.detail else { continue }
                let window = limit.window
                let windowSeconds = window?.duration.flatMap { duration -> TimeInterval? in
                    guard duration > 0 else { return nil }
                    return secondsPerUnit(window?.timeUnit).map { TimeInterval(duration) * $0 }
                }
                quotas.append(makeQuota(
                    id: "kimi.code.window.\(index).\(window?.duration ?? 0)\(window?.timeUnit ?? "")",
                    title: "Окно",
                    limit: detail.limit?.value,
                    used: detail.used?.value,
                    remaining: detail.remaining?.value,
                    windowSeconds: windowSeconds,
                    resetTime: nil
                ))
            }
        }
        return quotas
    }
}
