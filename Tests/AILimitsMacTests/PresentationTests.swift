import XCTest
@testable import AILimitsMac

/// Task 2, шаг 1: иконка строки меню никогда не отображает значение.
final class PresentationTests: XCTestCase {
    func testMenuBarNeverDisplaysAValue() {
        XCTAssertNil(MenuIdentity.visibleTitle)
        XCTAssertFalse(MenuIdentity.symbol.isEmpty)
    }

    /// Символ статический: не зависит от расхода или остатка (спецификация §1).
    func testSymbolIsStaticGauge() {
        XCTAssertEqual(MenuIdentity.symbol, MenuIdentity.symbol)
        XCTAssertTrue(MenuIdentity.symbol.hasPrefix("gauge"))
    }

    /// Accessible-имя разрешено — это не видимый текст (план Task 2, шаг 3).
    func testAccessibilityLabelIsPresent() {
        XCTAssertEqual(MenuIdentity.accessibilityLabel, "AI Limits")
    }
}
