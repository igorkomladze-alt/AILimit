import Foundation

/// Task 7, шаг 4: событие по квоте.
public enum QuotaAlert: Equatable, Sendable {
    case threshold(Int)
    case recovered
}

/// Квотные эпизоды.
/// Срабатывание при remaining <= threshold; перевзвод строго remaining > threshold.
/// Стартовые пороги 20 и 5 (спецификация §8); recovery — после предупреждения
/// и остатка выше верхнего порога.
public enum QuotaAlertReducer {
    public static let thresholds: [Int] = [20, 5]

    @discardableResult
    public static func observe(
        remainingPercent: Double?,
        thresholds: [Int] = QuotaAlertReducer.thresholds,
        state: inout QuotaEpisode
    ) -> QuotaAlert? {
        guard let percent = remainingPercent, !percent.isNaN, percent >= 0, percent <= 100 else {
            return nil // неизвестное значение не меняет эпизод
        }

        let top = thresholds.max() ?? 20

        // Recovery: было предупреждение, не восстановлен, остаток выше верхнего порога.
        if percent > Double(top), state.hadWarning, !state.isRecovered {
            state.isRecovered = true
            state.sentThresholds = []
            return .recovered
        }

        // Достигнутые сейчас пороги.
        let crossed = thresholds.filter { percent <= Double($0) }

        // Перевзвод: порог, выше которого мы поднялись, снова активен.
        state.sentThresholds = state.sentThresholds.filter { crossed.contains($0) }

        let newCrossed = crossed.filter { !state.sentThresholds.contains($0) }
        guard !newCrossed.isEmpty else { return nil }

        state.sentThresholds.formUnion(newCrossed)
        state.hadWarning = true
        state.isRecovered = false
        // Одно наиболее критичное событие за обновление (минимальный порог).
        return .threshold(newCrossed.min()!)
    }
}
