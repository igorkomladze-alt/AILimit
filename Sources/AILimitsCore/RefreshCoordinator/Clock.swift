import Foundation

/// Часы по контракту плана (раздел 3): now() + sleep(for:).
public protocol AppClock: Sendable {
    func now() -> Date
    func sleep(for seconds: TimeInterval) async throws
}

/// Системные часы.
public struct SystemClock: AppClock, Sendable {
    public init() {}
    public func now() -> Date { Date() }
    public func sleep(for seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

/// Часы для тестов: ручное управление временем, без реальных задержек.
public final class MockClock: AppClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    public init(start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        self.current = start
    }

    public func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    public func advance(by interval: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(interval)
    }

    public func set(_ date: Date) {
        lock.lock(); defer { lock.unlock() }
        current = date
    }

    public func sleep(for seconds: TimeInterval) async throws {
        // Тестовые часы не спят по-настоящему (спецификация §9).
    }
}
