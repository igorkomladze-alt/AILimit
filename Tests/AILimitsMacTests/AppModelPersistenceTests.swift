import XCTest
import Foundation
import AILimitsCore
@testable import AILimitsMac

/// Task 13 wiring, интеграционные: подключения и снимки переживают перезапуск,
/// уведомления не дублируются после рестарта (персистентные эпизоды + outbox).
@MainActor
final class AppModelPersistenceTests: XCTestCase {
    /// Фейковое хранилище секретов в памяти (Keychain в тестах не трогаем).
    final class FakeVault: SecretVault, @unchecked Sendable {
        var storage: [String: Data] = [:]
        func save(secret: Data, account: String) throws { storage[account] = secret }
        func delete(account: String) throws { storage.removeValue(forKey: account) }
        func resolve(connection: ConnectionRecord, interaction: CredentialInteraction) async throws -> AuthLease {
            let account = KeychainVault.account(for: connection)
            guard let data = storage[account] else { throw ProviderError.authenticationRequired }
            return AuthLease { String(data: data, encoding: .utf8) }
        }
    }

    /// Фейковая доставка: фиксирует события; «система» помнит доставленные ID.
    final class FakeNotifications: NotificationDelivering, @unchecked Sendable {
        var delivered: [AlertEvent] = []
        var granted = true
        func requestPermission() async -> Bool { granted }
        func authorizationGranted() async -> Bool { granted }
        func deliver(_ event: AlertEvent) async throws { delivered.append(event) }
        func knownEventIDs() async -> Set<String> { Set(delivered.map(\.id)) }
        func removePending(ids: [String]) {}
    }

    /// Фейковый провайдер OpenRouter с заданным балансом.
    struct FakeOpenRouter: UsageProvider {
        let id: ProviderID = .openrouter
        let balance: Decimal
        func fetch(connection: ConnectionID) async throws -> UsageSnapshot {
            UsageSnapshot(
                connection: connection, source: "fake.v1", fetchedAt: Date(),
                quotas: [], balanceUSD: balance)
        }
    }

    nonisolated(unsafe) private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-limits-appmodel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeModel(balance: Decimal, vault: FakeVault, notifications: FakeNotifications) -> AppModel {
        AppModel(
            stateFile: AtomicStateFile(directory: tempDir),
            alertFile: AlertStateFile(alertsIn: tempDir),
            notifications: notifications,
            systemEvents: SystemEvents(),
            codexServer: CodexServerController(
                locator: CodexExecutableLocator(candidates: [tempDir.appendingPathComponent("nope")]),
                home: tempDir.appendingPathComponent("codex-home", isDirectory: true),
                userHome: tempDir.appendingPathComponent("foreign-codex", isDirectory: true)),
            vault: vault,
            providers: [.openrouter: FakeOpenRouter(balance: balance)]
        )
    }

    /// Ожидание условия с дедлайном (асинхронные Task внутри модели).
    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    /// Подключение + снимок переживают «перезапуск» (новый AppModel на тех же файлах).
    func testConnectionAndSnapshotSurviveRestart() async throws {
        let vault = FakeVault()
        let notifications = FakeNotifications()
        let modelA = makeModel(balance: 12.50, vault: vault, notifications: notifications)
        modelA.pendingOpenRouterKey = "sk-test-fake"
        try modelA.connectOpenRouter()

        let connected = await waitUntil {
            modelA.cards.first { $0.provider == .openrouter }?.snapshot != nil
        }
        XCTAssertTrue(connected, "модель A должна получить снимок")
        modelA.shutdown()

        // «Перезапуск»: новая модель, те же файлы и тот же vault (Keychain переживает).
        let modelB = makeModel(balance: 12.50, vault: vault, notifications: notifications)
        let restored = await waitUntil {
            modelB.isRestored
                && modelB.cards.first { $0.provider == .openrouter }?.connection != nil
        }
        XCTAssertTrue(restored, "модель B должна восстановить подключение")
        let snapshot = modelB.cards.first { $0.provider == .openrouter }?.snapshot
        XCTAssertEqual(snapshot?.balanceUSD, 12.50)
        modelB.shutdown()
    }

    /// Низкий баланс: одно уведомление; после «перезапуска» повторной доставки нет.
    func testLowBalanceAlertNotDuplicatedAcrossRestart() async throws {
        let vault = FakeVault()
        let notificationsA = FakeNotifications()
        let modelA = makeModel(balance: 2.50, vault: vault, notifications: notificationsA)
        await modelA.setNotificationsEnabled(true)
        modelA.pendingOpenRouterKey = "sk-test-fake"
        try modelA.connectOpenRouter()

        let alerted = await waitUntil { notificationsA.delivered.count == 1 }
        XCTAssertTrue(alerted, "ровно одно событие о низком балансе")
        modelA.shutdown()

        // Перезапуск: эпизод isBelow сохранён, система знает ID — дублей нет.
        let notificationsB = FakeNotifications()
        notificationsB.delivered = notificationsA.delivered // система помнит доставленное
        let modelB = makeModel(balance: 2.50, vault: vault, notifications: notificationsB)
        let restored = await waitUntil { modelB.isRestored }
        XCTAssertTrue(restored)
        await modelB.refresh(reason: .manual)
        // delivered общий: было 1, новых не добавилось.
        XCTAssertEqual(notificationsB.delivered.count, 1, "повторная доставка запрещена")
        modelB.shutdown()
    }

    func testStorageErrorClearsOnlyAfterBothFilesRecover() async throws {
        let model = makeModel(balance: 10, vault: FakeVault(), notifications: FakeNotifications())
        _ = await waitUntil { model.isRestored }
        let stateURL = tempDir.appendingPathComponent("state.json")
        try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: false)
        let alertURL = tempDir.appendingPathComponent("alerts.json")
        try FileManager.default.removeItem(at: alertURL)
        try FileManager.default.createDirectory(at: alertURL, withIntermediateDirectories: false)
        model.pendingOpenRouterKey = "fake"
        try model.connectOpenRouter()
        _ = await waitUntil { model.cards.first { $0.provider == .openrouter }?.snapshot != nil }
        XCTAssertNotNil(model.storageError)
        try FileManager.default.removeItem(at: alertURL)
        model.setAlertPreference(provider: .openrouter, warnings: true, recovery: true)
        XCTAssertNotNil(model.storageError, "успешный alerts не скрывает ошибку state")
        try FileManager.default.removeItem(at: stateURL)
        await model.refresh(reason: .manual)
        XCTAssertNil(model.storageError)
        model.shutdown()
    }

    func testStaleObservationDoesNotRearmBalanceEpisode() async throws {
        let model = makeModel(balance: 10, vault: FakeVault(), notifications: FakeNotifications())
        _ = await waitUntil { model.isRestored }
        let connection = ConnectionID(provider: .openrouter, generation: UUID())
        func snapshot(_ balance: Decimal, stale: Bool = false) -> UsageSnapshot {
            UsageSnapshot(connection: connection, source: "test", fetchedAt: Date(),
                          observedAt: stale ? Date().addingTimeInterval(-601) : nil,
                          quotas: [], balanceUSD: balance)
        }
        XCTAssertEqual(model.evaluate(snapshot: snapshot(1)).count, 1)
        XCTAssertTrue(model.evaluate(snapshot: snapshot(10, stale: true)).isEmpty)
        XCTAssertTrue(model.evaluate(snapshot: snapshot(1)).isEmpty, "старое пополнение не перевзводит эпизод")
        model.shutdown()
    }

    func testExpiredQuotaDoesNotMutateEpisode() async throws {
        let model = makeModel(balance: 10, vault: FakeVault(), notifications: FakeNotifications())
        _ = await waitUntil { model.isRestored }
        let connection = ConnectionID(provider: .kimi, generation: UUID())
        func snapshot(_ remaining: Decimal, expired: Bool = false) -> UsageSnapshot {
            let now = Date()
            return UsageSnapshot(connection: connection, source: "test",
                fetchedAt: expired ? now.addingTimeInterval(-20) : now,
                quotas: [UsageQuota(id: "q", title: "Quota", value: .remainingPercent(remaining),
                                    resetsAt: expired ? now.addingTimeInterval(-10) : nil)])
        }
        XCTAssertEqual(model.evaluate(snapshot: snapshot(4)).count, 1)
        XCTAssertTrue(model.evaluate(snapshot: snapshot(90, expired: true)).isEmpty)
        XCTAssertTrue(model.evaluate(snapshot: snapshot(4)).isEmpty)
        model.shutdown()
    }

    func testSuppressedInitialWarningDoesNotCreateRecovery() async throws {
        for globallyEnabled in [false, true] {
            let notifications = FakeNotifications()
            let model = makeModel(balance: 10, vault: FakeVault(), notifications: notifications)
            _ = await waitUntil { model.isRestored }
            if globallyEnabled {
                await model.setNotificationsEnabled(true)
                model.setAlertPreference(provider: .kimi, warnings: false, recovery: true)
            }
            let connection = ConnectionID(provider: .kimi, generation: UUID())
            func snapshot(_ remaining: Decimal) -> UsageSnapshot {
                UsageSnapshot(connection: connection, source: "test", fetchedAt: Date(),
                    quotas: [UsageQuota(id: "q", title: "Quota", value: .remainingPercent(remaining))])
            }
            _ = model.evaluate(snapshot: snapshot(10))
            await model.setNotificationsEnabled(true)
            XCTAssertTrue(model.evaluate(snapshot: snapshot(80)).isEmpty,
                          "без первоначального предупреждения recovery не создается")
            XCTAssertTrue(notifications.delivered.isEmpty)
            model.shutdown()
        }
    }

    func testQuotaWarningsCombinedAndRecoveryIncludesRemaining() async throws {
        let model = makeModel(balance: 10, vault: FakeVault(), notifications: FakeNotifications())
        _ = await waitUntil { model.isRestored }
        await model.setNotificationsEnabled(true)
        let connection = ConnectionID(provider: .kimi, generation: UUID())
        func snapshot(_ remaining: Decimal) -> UsageSnapshot {
            UsageSnapshot(connection: connection, source: "test", fetchedAt: Date(), quotas: [
                UsageQuota(id: "short", title: "Короткое окно", value: .remainingPercent(remaining)),
                UsageQuota(id: "week", title: "Неделя", value: .remainingPercent(remaining))])
        }
        let warning = model.evaluate(snapshot: snapshot(4))
        XCTAssertEqual(warning.count, 1)
        XCTAssertTrue(warning[0].body.contains("Короткое окно"))
        XCTAssertTrue(warning[0].body.contains("Неделя"))
        let recovery = model.evaluate(snapshot: snapshot(80))
        XCTAssertEqual(recovery.count, 1)
        XCTAssertTrue(recovery[0].body.contains("80%"))
        _ = model.evaluate(snapshot: snapshot(4))
        XCTAssertEqual(model.evaluate(snapshot: snapshot(70)).count, 1, "второй эпизод тоже восстанавливается")
        model.setAlertPreference(provider: .kimi, warnings: true, recovery: false)
        XCTAssertEqual(model.evaluate(snapshot: snapshot(4)).count, 1)
        XCTAssertTrue(model.evaluate(snapshot: snapshot(80)).isEmpty)
        model.shutdown()
    }

    func testProviderCategoryPreferencesPersistAndSuppressWarnings() async throws {
        let notifications = FakeNotifications()
        let model = makeModel(balance: 10, vault: FakeVault(), notifications: notifications)
        _ = await waitUntil { model.isRestored }
        model.setAlertPreference(provider: .openrouter, warnings: false, recovery: true)
        let snapshot = UsageSnapshot(connection: ConnectionID(provider: .openrouter, generation: UUID()),
                                     source: "test", fetchedAt: Date(), quotas: [], balanceUSD: 1)
        XCTAssertTrue(model.evaluate(snapshot: snapshot).isEmpty)
        model.shutdown()
        let restored = makeModel(balance: 10, vault: FakeVault(), notifications: notifications)
        XCTAssertEqual(restored.alertPreferences[.openrouter], AlertPreference(warnings: false, recovery: true))
        _ = await waitUntil { restored.isRestored }
        restored.shutdown()
    }

    func testDisabledAlertsDoNotReplayAfterRecoveryAndEnable() async throws {
        let vault = FakeVault(), notifications = FakeNotifications()
        let low = makeModel(balance: 2, vault: vault, notifications: notifications)
        low.pendingOpenRouterKey = "fake"
        try low.connectOpenRouter()
        _ = await waitUntil { low.cards.first { $0.provider == .openrouter }?.snapshot != nil }
        low.shutdown()
        let recovered = makeModel(balance: 10, vault: vault, notifications: notifications)
        _ = await waitUntil { recovered.isRestored }
        await recovered.refresh(reason: .manual)
        await recovered.setNotificationsEnabled(true)
        XCTAssertTrue(notifications.delivered.isEmpty)
        recovered.shutdown()
    }

    func testFastCardUpdatesWhileSlowProviderIsPending() async throws {
        actor SlowProvider: UsageProvider {
            let id: ProviderID = .kimi
            var pending: CheckedContinuation<UsageSnapshot, Error>?
            func fetch(connection: ConnectionID) async throws -> UsageSnapshot {
                try await withCheckedThrowingContinuation { pending = $0 }
            }
            func finish() { pending?.resume(throwing: ProviderError.cancelled); pending = nil }
        }
        var envelope = AppEnvelope()
        for provider in [ProviderID.openrouter, .kimi] {
            let record = ConnectionRecord(id: ConnectionID(provider: provider, generation: UUID()),
                                          source: .manualKey, verifiedIdentityHash: nil)
            envelope.connections[provider.rawValue] = .init(record: record)
        }
        try AtomicStateFile(directory: tempDir).write(envelope)
        let slow = SlowProvider()
        let model = AppModel(stateFile: AtomicStateFile(directory: tempDir),
            alertFile: AlertStateFile(alertsIn: tempDir), notifications: FakeNotifications(),
            systemEvents: SystemEvents(), codexServer: CodexServerController(
                locator: CodexExecutableLocator(candidates: [tempDir.appendingPathComponent("nope")]),
                home: tempDir.appendingPathComponent("isolated"), userHome: tempDir.appendingPathComponent("foreign")),
            vault: FakeVault(), providers: [.openrouter: FakeOpenRouter(balance: 10), .kimi: slow])
        _ = await waitUntil { model.isRestored }
        let refresh = Task { await model.refresh(reason: .manual) }
        let displayed = await waitUntil { model.cards.first { $0.provider == .openrouter }?.snapshot != nil }
        XCTAssertTrue(displayed)
        XCTAssertNil(model.cards.first { $0.provider == .kimi }?.snapshot)
        await slow.finish()
        await refresh.value
        model.shutdown()
    }

    func testRearmedBalanceAfterRestartHasNewEventID() async throws {
        let vault = FakeVault()
        let notifications = FakeNotifications()
        let low = makeModel(balance: 2, vault: vault, notifications: notifications)
        await low.setNotificationsEnabled(true)
        low.pendingOpenRouterKey = "fake"
        try low.connectOpenRouter()
        _ = await waitUntil { notifications.delivered.count == 1 }
        low.shutdown()

        let replenished = makeModel(balance: 10, vault: vault, notifications: notifications)
        _ = await waitUntil { replenished.isRestored }
        await replenished.refresh(reason: .manual)
        XCTAssertEqual(notifications.delivered.count, 1)
        replenished.shutdown()

        let lowAgain = makeModel(balance: 2, vault: vault, notifications: notifications)
        _ = await waitUntil { lowAgain.isRestored }
        await lowAgain.refresh(reason: .manual)
        XCTAssertEqual(notifications.delivered.count, 2)
        XCTAssertEqual(Set(notifications.delivered.map(\.id)).count, 2)
        lowAgain.shutdown()
    }

    func testFailedAlertWriteDoesNotDeliverAndRetriesAfterRecovery() async throws {
        let notifications = FakeNotifications()
        let model = makeModel(balance: 2, vault: FakeVault(), notifications: notifications)
        _ = await waitUntil { model.isRestored }
        await model.setNotificationsEnabled(true)
        let alertURL = tempDir.appendingPathComponent("alerts.json")
        try FileManager.default.removeItem(at: alertURL)
        try FileManager.default.createDirectory(at: alertURL, withIntermediateDirectories: false)
        model.pendingOpenRouterKey = "fake"
        try model.connectOpenRouter()
        _ = await waitUntil { model.cards.first { $0.provider == .openrouter }?.snapshot != nil }
        await model.refresh(reason: .manual)
        XCTAssertTrue(notifications.delivered.isEmpty)
        try FileManager.default.removeItem(at: alertURL)
        await model.refresh(reason: .manual)
        XCTAssertEqual(notifications.delivered.count, 1)
        model.shutdown()
    }

    /// Ошибка обновления не стирает сохранённый снимок.
    func testFailureKeepsSnapshot() async throws {
        let vault = FakeVault()
        let notifications = FakeNotifications()
        let modelA = makeModel(balance: 12.50, vault: vault, notifications: notifications)
        modelA.pendingOpenRouterKey = "sk-test-fake"
        try modelA.connectOpenRouter()
        _ = await waitUntil {
            modelA.cards.first { $0.provider == .openrouter }?.snapshot != nil
        }
        modelA.shutdown()

        // Перезапуск с «упавшим» провайдером.
        struct FailingProvider: UsageProvider {
            let id: ProviderID = .openrouter
            func fetch(connection: ConnectionID) async throws -> UsageSnapshot {
                throw ProviderError.network
            }
        }
        let modelB = AppModel(
            stateFile: AtomicStateFile(directory: tempDir),
            alertFile: AlertStateFile(alertsIn: tempDir),
            notifications: notifications,
            systemEvents: SystemEvents(),
            codexServer: CodexServerController(
                locator: CodexExecutableLocator(candidates: [tempDir.appendingPathComponent("nope")]),
                home: tempDir.appendingPathComponent("codex-home", isDirectory: true),
                userHome: tempDir.appendingPathComponent("foreign-codex", isDirectory: true)),
            vault: vault,
            providers: [.openrouter: FailingProvider()]
        )
        _ = await waitUntil { modelB.isRestored }
        await modelB.refresh(reason: .manual)
        let card = modelB.cards.first { $0.provider == .openrouter }
        XCTAssertEqual(card?.lastError, .network)
        XCTAssertEqual(card?.snapshot?.balanceUSD, 12.50, "снимок сохраняется при ошибке")
        modelB.shutdown()
    }

    /// Отключение удаляет подключение и секрет, персистентно.
    func testDisconnectPersists() async throws {
        let vault = FakeVault()
        let notifications = FakeNotifications()
        let modelA = makeModel(balance: 12.50, vault: vault, notifications: notifications)
        modelA.pendingOpenRouterKey = "sk-test-fake"
        try modelA.connectOpenRouter()
        _ = await waitUntil {
            modelA.cards.first { $0.provider == .openrouter }?.connection != nil
        }
        await modelA.disconnect(.openrouter)
        let cleared = await waitUntil {
            vault.storage.isEmpty
        }
        XCTAssertTrue(cleared, "секрет удалён из хранилища")
        modelA.shutdown()

        let modelB = makeModel(balance: 12.50, vault: vault, notifications: notifications)
        let restored = await waitUntil { modelB.isRestored }
        XCTAssertTrue(restored)
        XCTAssertNil(modelB.cards.first { $0.provider == .openrouter }?.connection)
        modelB.shutdown()
    }
}
