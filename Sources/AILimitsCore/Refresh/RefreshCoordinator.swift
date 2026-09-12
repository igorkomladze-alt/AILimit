import Foundation

/// Task 6, шаг 4: координатор обновлений.
/// - Максимум 3 параллельных слота; задачи одного сервиса сериализованы (inFlight per provider).
/// - Ручное обновление не дублирует текущий запрос и не обходит backoff/Retry-After.
/// - Медленный сервис не блокирует остальные (независимые задачи).
public actor RefreshCoordinator {
    /// Состояние одного провайдера.
    private struct ProviderState {
        var record: ConnectionRecord?
        var inFlight = false
        var failures = 0
        var nextEligibleAt = Date.distantPast
        var retryAfterUntil: Date?
    }

    private let providers: [ProviderID: any UsageProvider]
    private let clock: any AppClock
    private let maxConcurrent: Int
    private var states: [ProviderID: ProviderState] = [:]
    private var activeCount = 0
    private struct Job: Sendable {
        let record: ConnectionRecord
        let buffer: UpdateBuffer
    }
    private var queue: [Job] = []

    public init(
        providers: [ProviderID: any UsageProvider],
        clock: any AppClock = SystemClock(),
        maxConcurrent: Int = 3
    ) {
        self.providers = providers
        self.clock = clock
        self.maxConcurrent = maxConcurrent
        for id in providers.keys { states[id] = ProviderState() }
    }

    /// Зарегистрировать/заменить подключение: сброс backoff (новое поколение — новая история).
    public func setConnection(_ record: ConnectionRecord) {
        var state = states[record.id.provider] ?? ProviderState()
        state.record = record
        state.failures = 0
        state.retryAfterUntil = nil
        state.nextEligibleAt = clock.now()
        states[record.id.provider] = state
    }

    public func removeConnection(_ provider: ProviderID) {
        states[provider]?.record = nil
    }

    /// Запросить обновление подключённых провайдеров.
    /// Сверх лимита слотов провайдеры ставятся в очередь и стартуют по мере
    /// освобождения (а не пропускаются до следующего цикла).
    /// onUpdate получает результаты сразу; возвращаемый массив — после завершения этого request.
    public func request(
        providers ids: [ProviderID], reason: RefreshReason,
        onUpdate: (@Sendable (ProviderUpdate) async -> Void)? = nil
    ) async -> [ProviderUpdate] {
        let buffer = UpdateBuffer()
        var expected = 0
        for id in ids {
            guard var state = states[id], let record = state.record,
                  RefreshPolicy.canStart(now: clock.now(), nextEligibleAt: state.nextEligibleAt,
                                         inFlight: state.inFlight) else { continue }
            // Резервируем провайдера уже в очереди: второй request его не дублирует.
            state.inFlight = true
            states[id] = state
            queue.append(Job(record: record, buffer: buffer))
            expected += 1
        }
        startQueued()
        var collected: [ProviderUpdate] = []
        for _ in 0..<expected {
            let update = await buffer.next()
            collected.append(update)
            await onUpdate?(update)
        }
        return collected
    }

    private func startQueued() {
        while activeCount < max(1, maxConcurrent), !queue.isEmpty {
            let job = queue.removeFirst()
            activeCount += 1
            Task { await performRefresh(job) }
        }
    }

    private func performRefresh(_ job: Job) async {
        let record = job.record
        let provider = record.id.provider
        let result: Result<UsageSnapshot, ProviderError>
        if states[provider]?.record?.id != record.id {
            result = .failure(.cancelled)
        } else if let implementation = providers[provider] {
            do { result = .success(try await implementation.fetch(connection: record.id)) }
            catch let error as ProviderError { result = .failure(error) }
            catch { result = .failure(.network) }
        } else {
            result = .failure(.unsupportedSource)
        }
        var state = states[provider] ?? ProviderState()
        state.inFlight = false
        let current = state.record?.id == record.id
        if current {
            switch result {
            case .success: state.failures = 0
            case .failure(let error):
                if error != .cancelled { state.failures += 1 }
                if case .rateLimited(let until) = error { state.retryAfterUntil = until }
            }
            if let until = state.retryAfterUntil, until > clock.now() {
                state.nextEligibleAt = until
            } else {
                state.nextEligibleAt = clock.now().addingTimeInterval(
                    RefreshPolicy.backoffSeconds(failures: state.failures))
                state.retryAfterUntil = nil
            }
        }
        // Старый ответ освобождает слот, но не меняет backoff нового поколения.
        states[provider] = state
        activeCount -= 1
        startQueued()
        await job.buffer.push(ProviderUpdate(connection: record.id,
            result: current ? result : .failure(.cancelled)))
    }

}

/// Простой буфер обновлений (continuation-очередь).
package actor UpdateBuffer {
    private var storage: [ProviderUpdate] = []
    private var continuations: [CheckedContinuation<ProviderUpdate, Never>] = []

    package init() {}

    package func push(_ update: ProviderUpdate) {
        if continuations.isEmpty {
            storage.append(update)
        } else {
            continuations.removeFirst().resume(returning: update)
        }
    }

    package func next() async -> ProviderUpdate {
        if let first = storage.first {
            storage.removeFirst()
            return first
        }
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }
}
