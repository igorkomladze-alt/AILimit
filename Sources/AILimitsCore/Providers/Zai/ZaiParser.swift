import Foundation

/// Task 9, шаг 3: парсер Z.ai quota/limit (R6/R7).
/// TOKENS_LIMIT/CREDIT_LIMIT → coding; TIME_LIMIT → mcp.
/// percentage — расход, вывод 100 − percentage. nextResetTime — epoch MILLISECONDS.
public enum ZaiParser {
    private struct Envelope: Decodable {
        struct Limit: Decodable {
            let type: String?
            let unit: Int?
            let number: Int?
            let percentage: Decimal?
            let nextResetTime: Decimal?
        }
        struct Data: Decodable {
            let limits: [Limit]?
        }
        let success: Bool?
        let code: Int?
        let data: Data?
    }

    private static func secondsPerUnit(_ unit: Int?) -> TimeInterval? {
        // 1=days, 3=hours, 5=minutes, 6=weeks (R7).
        switch unit {
        case 1: return 86400
        case 3: return 3600
        case 5: return 60
        case 6: return 604800
        default: return nil
        }
    }

    public static func quotas(from data: Data, now: Date) throws -> [UsageQuota] {
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw ProviderError.invalidData
        }
        // DTO проверяет success == true и code == 200.
        guard envelope.success == true, envelope.code == 200 else {
            throw ProviderError.invalidData
        }
        guard let limits = envelope.data?.limits else { throw ProviderError.invalidData }

        var quotas: [UsageQuota] = []
        for (index, limit) in limits.enumerated() {
            guard let type = limit.type else { continue }
            let scope: String
            switch type {
            case "TOKENS_LIMIT", "CREDIT_LIMIT": scope = "coding"
            case "TIME_LIMIT": scope = "mcp"
            default: continue // неизвестный тип не ломает соседей
            }

            // percentage — расход; вывод 100 − percentage; вне 0…100 → unknown.
            let value: QuotaValue
            if let used = limit.percentage, !used.isNaN, used >= 0, used <= 100 {
                value = .remainingPercent(100 - used)
            } else {
                value = .unknown
            }

            let windowSeconds = limit.unit.flatMap { unit -> TimeInterval? in
                guard let perUnit = secondsPerUnit(unit) else { return nil }
                guard let number = limit.number, number > 0 else { return nil }
                return TimeInterval(number) * perUnit
            }

            // nextResetTime — epoch milliseconds; невалидный → nil, без сдвига часовых поясов.
            let reset: Date?
            if let ms = limit.nextResetTime {
                let msDouble = NSDecimalNumber(decimal: ms).doubleValue
                let seconds = msDouble / 1000
                let candidate = Date(timeIntervalSince1970: seconds)
                // Отсекаем правдоподобно-невозможные даты (до 2020 или после 2100).
                reset = (candidate > Date(timeIntervalSince1970: 1_577_836_800)
                         && candidate < Date(timeIntervalSince1970: 4_102_444_800)) ? candidate : nil
            } else {
                reset = nil
            }

            quotas.append(UsageQuota(
                id: "zai.\(scope).\(index)",
                title: scope == "coding" ? "Coding Plan" : "MCP",
                scope: scope,
                value: value,
                windowSeconds: windowSeconds,
                resetsAt: reset
            ))
        }
        return quotas
    }
}
