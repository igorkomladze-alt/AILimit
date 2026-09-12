import Foundation

/// Task 6, шаг 3: чистая политика обновления.
/// Backoff: 5 мин (штатно) → 10 → 20 → 30 мин; Retry-After имеет абсолютный приоритет.
public enum RefreshPolicy {
    /// Штатный интервал и backoff-лестница после временных ошибок.
    public static func backoffSeconds(failures: Int) -> TimeInterval {
        switch failures {
        case ...0: return 300
        case 1: return 600
        case 2: return 1200
        default: return 1800
        }
    }

    /// Ранний момент следующей попытки: максимум между backoff и Retry-After.
    public static func earliestRetry(failureAt: Date, failures: Int, retryAfter: Date?) -> Date {
        max(failureAt.addingTimeInterval(backoffSeconds(failures: failures)), retryAfter ?? failureAt)
    }

    /// Решение о старте: не in-flight И срок наступил.
    public static func canStart(now: Date, nextEligibleAt: Date, inFlight: Bool) -> Bool {
        !inFlight && now >= nextEligibleAt
    }
}
