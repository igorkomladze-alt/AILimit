import XCTest
import Foundation
@testable import AILimitsMac

/// Task 13, шаг 1/2: форматирование не скрывает пересечение порога
/// и не «восстанавливает» квоту арифметически.
final class ValueFormattingTests: XCTestCase {
    /// 2.9999 не должно отображаться как 3.00 (порог $3 строгий).
    func testThresholdFormattingDoesNotHideALowBalance() {
        let locale = Locale(identifier: "en_US_POSIX")
        let below = ValueFormatting.usd(Decimal(string: "2.9999")!, threshold: 3, locale: locale)
        let exact = ValueFormatting.usd(3, threshold: 3, locale: locale)
        XCTAssertTrue(below.contains("2.9999"), "получено: \(below)")
        XCTAssertTrue(exact.contains("3.00"), "получено: \(exact)")
        XCTAssertFalse(below.contains("3.00"))
    }

    /// Обычные значения — два знака.
    func testRegularBalanceTwoDigits() {
        let locale = Locale(identifier: "en_US_POSIX")
        XCTAssertTrue(ValueFormatting.usd(Decimal(string: "12.34")!, threshold: 3, locale: locale).contains("12.34"))
        XCTAssertTrue(ValueFormatting.usd(Decimal(string: "0.5")!, threshold: 3, locale: locale).contains("0.50"))
    }

    /// Отрицательный баланс не обрезается до нуля.
    func testNegativeBalanceNotClamped() {
        let locale = Locale(identifier: "en_US_POSIX")
        let text = ValueFormatting.usd(Decimal(string: "-1.25")!, threshold: 3, locale: locale)
        XCTAssertTrue(text.contains("-1.25"), "получено: \(text)")
    }

    /// Истёкший reset без подтверждения — «Проверяем восстановление», не 100%.
    func testExpiredResetDoesNotSayOneHundredPercent() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(ValueFormatting.resetLabel(resetAt: now, now: now, confirmed: false),
            "Проверяем восстановление")
    }

    /// Будущий reset — относительное время.
    func testFutureResetShowsRemaining() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let label = ValueFormatting.resetLabel(resetAt: now.addingTimeInterval(5 * 3600 + 30 * 60), now: now, confirmed: false)
        XCTAssertTrue(label.contains("5 ч"), "получено: \(label)")
    }

    /// Подтверждённое восстановление после истёкшего reset.
    func testExpiredResetConfirmed() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(ValueFormatting.resetLabel(resetAt: now, now: now, confirmed: true), "Восстановлено")
    }

    /// Отсутствие reset — честное «нет данных».
    func testMissingResetHonest() {
        XCTAssertEqual(ValueFormatting.resetLabel(resetAt: nil, now: Date(), confirmed: false), "Сброс: нет данных")
    }

    /// Подписи окон: 5 ч и 7 дн.
    func testWindowLabels() {
        XCTAssertEqual(ValueFormatting.windowLabel(windowSeconds: 5 * 3600), "5 ч")
        XCTAssertEqual(ValueFormatting.windowLabel(windowSeconds: 7 * 24 * 3600), "7 дн")
        XCTAssertNil(ValueFormatting.windowLabel(windowSeconds: nil))
    }
}
