import Foundation

/// Политика свежести снимка (план Task 5; спецификация §7).
/// Порог 600 секунд сравнивается с исходным fetchedAt и, если есть, более ранним observedAt.
public enum SnapshotPolicy {
    /// Данные устарели: возраст больше 10 минут, последний refresh не удался
    /// или подтверждённый reset истёк без последующего успешного чтения.
    public static func isFresh(
        fetchedAt: Date,
        observedAt: Date?,
        lastRefreshFailed: Bool,
        resetAt: Date?,
        now: Date
    ) -> Bool {
        let effective = min(fetchedAt, observedAt ?? fetchedAt)
        guard !lastRefreshFailed, effective <= now,
              now.timeIntervalSince(effective) <= 600 else { return false }
        if let resetAt, resetAt <= now, effective <= resetAt { return false }
        return true
    }
}
