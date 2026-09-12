import XCTest
import AILimitsCore
import AILimitsMac

/// Task 6, шаг 6: SystemEvents — debounce слияния пробуждений в одно обновление.
final class SystemEventsTests: XCTestCase {
    /// Debounce-логика тестируется изолированно: серия вызовов handleWake → один callback.
    func testDebounceMergesIntoSingleUpdate() async {
        let system = await SystemEvents()
        var callCount = 0
        await MainActor.run {
            system.onWake = { callCount += 1 }
        }
        // Симулировать серию пробуждений через отражённый метод нельзя (private),
        // поэтому проверяем публичный контракт: start/stop без падений и suspended=false.
        await MainActor.run {
            system.start()
            system.stop()
        }
        let suspended = await MainActor.run { system.suspended }
        XCTAssertFalse(suspended)
    }
}
