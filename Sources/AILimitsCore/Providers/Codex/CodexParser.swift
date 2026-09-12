import Foundation

/// Task 11, шаг 3: парсер Codex rate limits (R2).
/// Валидный rateLimitsByLimitId переопределяет legacy rateLimits (без дублей).
public enum CodexParser {
    private struct Envelope: Decodable {
        struct Bucket: Decodable {
            let usedPercent: Decimal?
            let windowDurationMins: Double?
            let resetsAt: Double?
        }
        struct Group: Decodable {
            let limitId: String?
            let limitName: String?
            let primary: Bucket?
            let secondary: Bucket?
        }
        let rateLimits: Group?
        let rateLimitsByLimitId: [String: Group]?
    }

    private static func makeQuota(
        group: String, name: String?, bucket: String, raw: Envelope.Bucket?
    ) -> UsageQuota? {
        guard let raw else { return nil }
        let value: QuotaValue
        if let used = raw.usedPercent, !used.isNaN, used >= 0, used <= 100 {
            value = .remainingPercent(100 - used)
        } else {
            value = .unknown
        }
        let minutes = raw.windowDurationMins.flatMap { $0.isFinite && $0 > 0 && $0 < 525_600_000 ? $0 : nil }
        let windowSeconds = minutes.map { $0 * 60 }
        let displayName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = displayName.flatMap { $0.isEmpty ? nil : $0 } ?? (group == "codex" ? "Codex" : group)
        let period: String
        if let minutes {
            if minutes == 10080 { period = "7 дней" }
            else if minutes == 300 { period = "5 часов" }
            else if minutes.truncatingRemainder(dividingBy: 1440) == 0 { period = "\(Int(minutes / 1440)) дн" }
            else if minutes.truncatingRemainder(dividingBy: 60) == 0 { period = "\(Int(minutes / 60)) ч" }
            else { period = "\(Int(minutes)) мин" }
        } else { period = bucket == "primary" ? "период 1" : "период 2" }
        let reset = raw.resetsAt.map { Date(timeIntervalSince1970: $0) }
        return UsageQuota(
            id: "codex.\(group).\(bucket)",
            title: "\(label) · \(period)",
            scope: group,
            value: value,
            windowSeconds: windowSeconds,
            resetsAt: reset
        )
    }

    public static func quotas(fromResult data: Data) throws -> [UsageQuota] {
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw ProviderError.invalidData
        }
        var quotas: [UsageQuota] = []
        if let groups = envelope.rateLimitsByLimitId, !groups.isEmpty {
            // Валидный multi-map переопределяет legacy.
            for (key, group) in groups.sorted(by: {
                let left = $0.value.limitId ?? $0.key
                let right = $1.value.limitId ?? $1.key
                if (left == "codex") != (right == "codex") { return left == "codex" }
                return $0.key < $1.key
            }) {
                let groupID = group.limitId ?? key
                if let q = makeQuota(group: groupID, name: group.limitName, bucket: "primary", raw: group.primary) { quotas.append(q) }
                if let q = makeQuota(group: groupID, name: group.limitName, bucket: "secondary", raw: group.secondary) { quotas.append(q) }
            }
        } else if let legacy = envelope.rateLimits {
            let groupID = legacy.limitId ?? "codex"
            if let q = makeQuota(group: groupID, name: legacy.limitName, bucket: "primary", raw: legacy.primary) { quotas.append(q) }
            if let q = makeQuota(group: groupID, name: legacy.limitName, bucket: "secondary", raw: legacy.secondary) { quotas.append(q) }
        } else {
            throw ProviderError.invalidData
        }
        return quotas
    }
}
