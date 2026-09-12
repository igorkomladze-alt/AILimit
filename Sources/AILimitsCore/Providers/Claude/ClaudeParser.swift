import Foundation

/// Task 10: парсер Claude oauth/usage (R4).
/// utilization — расход: остаток = 100 − utilization.
/// Известные окна получают стабильные ID; null/неизвестные окна пропускаются.
public enum ClaudeParser {
    private struct Envelope: Decodable {
        struct Window: Decodable {
            let utilization: Decimal?
            let resets_at: Decimal?
        }
        let five_hour: Window?
        let seven_day: Window?
        let seven_day_sonnet: Window?
        let seven_day_opus: Window?
    }

    private static func makeQuota(
        id: String, title: String, window: Envelope.Window?
    ) -> UsageQuota? {
        guard let window else { return nil } // null-окно: не квота, не 100%
        let value: QuotaValue
        if let utilization = window.utilization, !utilization.isNaN,
           utilization >= 0, utilization <= 100 {
            value = .remainingPercent(100 - utilization)
        } else {
            value = .unknown
        }
        // resets_at — epoch seconds.
        let reset: Date?
        if let raw = window.resets_at {
            let seconds = NSDecimalNumber(decimal: raw).doubleValue
            let candidate = Date(timeIntervalSince1970: seconds)
            reset = (candidate > Date(timeIntervalSince1970: 1_577_836_800)
                     && candidate < Date(timeIntervalSince1970: 4_102_444_800)) ? candidate : nil
        } else {
            reset = nil
        }
        return UsageQuota(id: id, title: title, value: value, resetsAt: reset)
    }

    public static func quotas(from data: Data) throws -> [UsageQuota] {
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw ProviderError.invalidData
        }
        // Объект должен содержать хотя бы одно известное окно или быть пустым usage-ответом;
        // ответ без полей окон вообще (например {"error":...}) — несовместимая схема.
        guard envelope.five_hour != nil || envelope.seven_day != nil
                || envelope.seven_day_sonnet != nil || envelope.seven_day_opus != nil else {
            throw ProviderError.invalidData
        }
        var quotas: [UsageQuota] = []
        if let q = makeQuota(id: "claude.five_hour", title: "5 часов", window: envelope.five_hour) { quotas.append(q) }
        if let q = makeQuota(id: "claude.seven_day", title: "Неделя", window: envelope.seven_day) { quotas.append(q) }
        if let q = makeQuota(id: "claude.seven_day_sonnet", title: "Неделя Sonnet", window: envelope.seven_day_sonnet) { quotas.append(q) }
        if let q = makeQuota(id: "claude.seven_day_opus", title: "Неделя Opus", window: envelope.seven_day_opus) { quotas.append(q) }
        return quotas
    }
}
