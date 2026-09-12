import XCTest
@testable import AILimitsCore

/// Task 3, шаг 1: поколение подключения сохраняется только при доказанном том же аккаунте.
final class ConnectionPolicyTests: XCTestCase {
    func testOnlyTwoVerifiedEqualIdentitiesCanReuseState() {
        XCTAssertTrue(ConnectionPolicy.canPreserveGeneration(oldIdentity: "a", newIdentity: "a"))
        XCTAssertFalse(ConnectionPolicy.canPreserveGeneration(oldIdentity: "a", newIdentity: "b"))
        XCTAssertFalse(ConnectionPolicy.canPreserveGeneration(oldIdentity: nil, newIdentity: nil))
        XCTAssertFalse(ConnectionPolicy.canPreserveGeneration(oldIdentity: "a", newIdentity: nil))
    }

    /// Пустая строка — не идентичность (план Task 3, шаг 3).
    func testEmptyIdentityIsNotVerified() {
        XCTAssertFalse(ConnectionPolicy.canPreserveGeneration(oldIdentity: "", newIdentity: ""))
        XCTAssertFalse(ConnectionPolicy.canPreserveGeneration(oldIdentity: "a", newIdentity: ""))
    }
}
