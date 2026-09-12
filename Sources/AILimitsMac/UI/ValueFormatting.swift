import Foundation

/// Task 13, шаг 1/3: форматирование значений панели.
/// Деньги — Decimal; точность увеличивается, если округление переносит значение
/// через порог (2.9999 не должно выглядеть как 3.00). Отрицательный баланс
/// не обрезается до нуля. Локаль — текущая, без жёсткого часового пояса.
public enum ValueFormatting {
    /// USD-строка. Минимум два знака; если округление до двух знаков переносит
    /// значение через threshold — показывается больше знаков (до 6).
    public static func usd(_ value: Decimal, threshold: Decimal, locale: Locale = .current) -> String {
        var fractionDigits = 2
        // Пока округление скрывает пересечение порога — добавляем точность.
        while fractionDigits < 6 {
            let formatted = format(value, fractionDigits: fractionDigits, locale: locale)
            let rounded = decimal(from: formatted, locale: locale)
            let crossesThreshold = (value < threshold) != (rounded < threshold)
            if !crossesThreshold || rounded == value { break }
            fractionDigits += 2
        }
        return "$" + format(value, fractionDigits: fractionDigits, locale: locale)
    }

    /// Подпись сброса квоты. Истёкший reset без подтверждённого восстановления —
    /// «Проверяем восстановление», арифметического восстановления нет (спецификация §6).
    public static func resetLabel(resetAt: Date?, now: Date, confirmed: Bool) -> String {
        guard let resetAt else { return "Сброс: нет данных" }
        if resetAt <= now {
            return confirmed ? "Восстановлено" : "Проверяем восстановление"
        }
        let interval = resetAt.timeIntervalSince(now)
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        if hours > 24 {
            return "Сброс: \(resetAt.formatted(date: .abbreviated, time: .shortened))"
        } else if hours > 0 {
            return "Сброс через \(hours) ч \(minutes) мин"
        } else {
            return "Сброс через \(max(minutes, 1)) мин"
        }
    }

    /// Возраст снимка (для деталей карточки).
    public static func ageLabel(since fetchedAt: Date, now: Date) -> String {
        let interval = max(0, now.timeIntervalSince(fetchedAt))
        let minutes = Int(interval) / 60
        if minutes < 1 { return "только что" }
        if minutes < 60 { return "\(minutes) мин назад" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) ч назад" }
        return fetchedAt.formatted(date: .abbreviated, time: .shortened)
    }

    /// Подпись окна квоты (5 ч / 7 дн).
    public static func windowLabel(windowSeconds: TimeInterval?) -> String? {
        guard let windowSeconds else { return nil }
        let hours = Int(windowSeconds) / 3600
        if hours >= 24, hours % 24 == 0 { return "\(hours / 24) дн" }
        if hours >= 1 { return "\(hours) ч" }
        return "\(Int(windowSeconds) / 60) мин"
    }

    // MARK: - Private

    private static func format(_ value: Decimal, fractionDigits: Int, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = fractionDigits
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? "\(value)"
    }

    private static func decimal(from string: String, locale: Locale) -> Decimal {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        guard let number = formatter.number(from: string) else { return valueFallback(string) }
        return number.decimalValue
    }

    private static func valueFallback(_ string: String) -> Decimal {
        Decimal(string: string) ?? 0
    }
}
