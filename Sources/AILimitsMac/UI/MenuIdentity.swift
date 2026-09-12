import Foundation

/// Task 2: идентичность иконки строки меню.
/// Единственная точка интеграции — иконка БЕЗ текста, цифр и badges (спецификация §1).
public enum MenuIdentity {
    /// Статический SF Symbol. Не меняется от расхода, остатка или состояния сервисов.
    public static let symbol = "gauge.with.dots.needle.bottom.50percent"

    /// Видимый текст рядом с иконкой запрещён. Всегда nil (план Task 2, шаг 1).
    public static let visibleTitle: String? = nil

    /// Accessibility-имя: разрешено, это не видимый текст.
    public static let accessibilityLabel = "AI Limits"
}
