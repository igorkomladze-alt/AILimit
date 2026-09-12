import Foundation
import SwiftUI
import Combine
import AILimitsCore
import UserNotifications

/// Task 4/6/13/14: модель панели с полной обвязкой.
/// - Персистентность: StateRepository + AtomicStateFile (state.json), AlertStateStore
///   (alerts.json) — подключения, снимки, эпизоды порогов и outbox переживают перезапуск.
/// - Обновления: RefreshCoordinator (3 слота, backoff 10/20/30 мин… нет — 5/10/20/30 по RefreshPolicy,
///   Retry-After приоритет). Таймер 5 минут; сон приостанавливает, wake — одно объединённое обновление.
/// - Уведомления: события → outbox → persist → доставка; повторная доставка подавляется
///   сверкой с известными системе ID.
/// UI не видит секретов — только снимки и типизированные ошибки.
@MainActor
public final class AppModel: ObservableObject {
    /// Состояние одной карточки.
    public struct CardState: Identifiable {
        public let provider: ProviderID
        public var connection: ConnectionRecord?
        public var snapshot: UsageSnapshot?
        public var lastError: ProviderError?
        public var isRefreshing = false

        public init(provider: ProviderID) {
            self.provider = provider
        }

        public var id: ProviderID { provider }
        public var isConnected: Bool { connection != nil }
    }

    @Published public var cards: [CardState]
    /// Ключи, вводимые в формы. Живут только здесь до сохранения в Keychain.
    @Published public var pendingOpenRouterKey = ""
    @Published public var pendingKimiKey = ""
    @Published public var pendingZaiKey = ""
    /// Показывать ли отключённые карточки.
    @Published public var showDisconnected = true {
        didSet { UserDefaults.standard.set(showDisconnected, forKey: Self.defaultsShowDisconnected) }
    }
    /// Уведомления включены пользователем (системное разрешение — отдельно).
    @Published public private(set) var notificationsEnabled = false
    @Published public private(set) var storageError: String?
    private var stateWriteFailed = false
    private var alertWriteFailed = false
    @Published public private(set) var alertPreferences: [ProviderID: AlertPreference] = [:]
    /// Системное разрешение на уведомления отклонено (для подсказки в настройках).
    @Published public private(set) var notificationsDenied = false
    /// Восстановление из файлов завершено (UI может показывать «загрузку»).
    @Published public private(set) var isRestored = false

    private static let defaultsShowDisconnected = "ailimits.showDisconnected"

    // MARK: - Зависимости

    private let vault: any SecretVault
    private let clock: any AppClock
    private let settings: AppSettings
    private let repository: StateRepository
    private let stateFile: AtomicStateFile
    private let alertFile: AlertStateFile
    private let coordinator: RefreshCoordinator
    private let notifications: any NotificationDelivering
    private let systemEvents: SystemEvents
    public let customServices: CustomServiceStore
    private var customServicesSubscription: AnyCancellable?
    public let loginItems: LoginItemController
    public let codexLogin: CodexLoginController
    private let codexServer: CodexServerController

    private var alertStore: AlertStateStore
    private var timerTask: Task<Void, Never>?
    /// Восстановление завершается до пользовательских операций.
    private var restorationTask: Task<Void, Never>?
    private var drainingOutbox = false
    private var registeringCodex = false
    private var codexCompletionSubscription: AnyCancellable?

    // MARK: - Инициализация

    public convenience init() {
        let supportDir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AILimits", isDirectory: true)
        let codexServer = CodexServerController()
        self.init(
            stateFile: AtomicStateFile(directory: supportDir),
            alertFile: AlertStateFile(alertsIn: supportDir),
            notifications: MacNotificationService(),
            systemEvents: SystemEvents(),
            loginItems: LoginItemController(),
            codexServer: codexServer
        )
    }

    /// Полная инъекция (тесты используют временные каталоги и фейковые сервисы).
    init(
        stateFile: AtomicStateFile,
        alertFile: AlertStateFile,
        notifications: any NotificationDelivering,
        systemEvents: SystemEvents,
        loginItems: LoginItemController? = nil,
        codexServer: CodexServerController,
        codexLogin: CodexLoginController? = nil,
        clock: any AppClock = SystemClock(),
        settings: AppSettings = .defaults,
        vault: (any SecretVault)? = nil,
        providers: [ProviderID: any UsageProvider]? = nil
    ) {
        self.stateFile = stateFile
        self.alertFile = alertFile
        self.notifications = notifications
        self.systemEvents = systemEvents
        self.loginItems = loginItems ?? LoginItemController()
        self.codexServer = codexServer
        self.codexLogin = codexLogin ?? CodexLoginController(server: codexServer)
        self.clock = clock
        self.settings = settings
        let vault = vault ?? KeychainVault()
        self.vault = vault
        self.customServices = CustomServiceStore(directory: stateFile.directory, vault: vault)

        // Восстановленное состояние (до первой записи — пустые).
        let restoredAlerts = alertFile.read() ?? AlertStateStore()
        self.alertStore = restoredAlerts
        self.notificationsEnabled = restoredAlerts.notificationsEnabled
        self.alertPreferences = Dictionary(uniqueKeysWithValues: (restoredAlerts.preferences ?? [:]).compactMap { key, value in
            ProviderID(rawValue: key).map { ($0, value) }
        })
        let restoredEnvelope = stateFile.read() ?? AppEnvelope()
        self.repository = StateRepository(envelope: restoredEnvelope, clock: clock)

        // Порядок спецификации §3: Claude, Codex, Kimi Code, GLM/Z.ai, OpenRouter.
        self.cards = ProviderID.allCases
            .sorted { $0.displayOrder < $1.displayOrder }
            .map { CardState(provider: $0) }

        if UserDefaults.standard.object(forKey: Self.defaultsShowDisconnected) != nil {
            self.showDisconnected = UserDefaults.standard.bool(forKey: Self.defaultsShowDisconnected)
        }

        // Провайдеры: read-only адаптеры, без генераций (в тестах — подменённые).
        var providers = providers ?? [:]
        if providers.isEmpty {
            let transport = URLSessionTransport()
            providers[.openrouter] = OpenRouterProvider(
                transport: transport, credentials: vault, clock: clock)
            providers[.kimi] = KimiProvider(
                transport: transport, credentials: KimiCredentialReader(vault: vault), clock: clock,
                recordResolver: { [repository] id in await repository.connection(for: id.provider) })
            providers[.zai] = ZaiProvider(
                transport: transport, credentials: vault, clock: clock)
            providers[.claude] = ClaudeProvider(
                transport: transport, credentials: ClaudeCredentialReader(), clock: clock)
            providers[.codex] = CodexProvider(server: codexServer, clock: clock)
        }
        self.coordinator = RefreshCoordinator(
            providers: providers, clock: clock, maxConcurrent: settings.maxConcurrent)

        systemEvents.onWake = { [weak self] in
            Task { await self?.refresh(reason: .wake) }
        }
        systemEvents.onSleep = { [weak self] in
            Task { await self?.codexServer.stop() }
        }
        systemEvents.start()

        restorationTask = Task { await self.restore() }
        codexCompletionSubscription = self.codexLogin.$state.sink { [weak self] state in
            guard state == .completed else { return }
            self?.finishCodexConnect()
        }
        customServicesSubscription = customServices.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        startTimer()
    }

    /// Восстановление подключений и снимков из repository; регистрация в координаторе;
    /// сверка outbox с системой; добивка pending-доставки.
    private func restore() async {
        for index in cards.indices {
            let provider = cards[index].provider
            if let connection = await repository.connection(for: provider) {
                cards[index].connection = connection
                await coordinator.setConnection(connection)
                cards[index].snapshot = await repository.snapshot(for: provider)
            }
        }
        if !alertStore.notificationsEnabled {
            notifications.removePending(ids: alertStore.outbox.pendingIDs)
            alertStore.outbox.removeAll { _ in true }
            persistAlerts()
        }
        // События, уже известные системе, не доставляются повторно.
        let known = await notifications.knownEventIDs()
        let before = alertStore.outbox.pending.count
        for id in known { alertStore.outbox.markDelivered(id: id) }
        if alertStore.outbox.pending.count != before { persistAlerts() }
        let authorizationGranted = await notifications.authorizationGranted()
        notificationsDenied = alertStore.permissionRequested && !authorizationGranted
        isRestored = true
        await drainOutbox()
    }

    // MARK: - Таймер (5 минут; сон приостанавливает)

    private func startTimer() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(self?.settings.refreshSeconds ?? 300) * 1_000_000_000)
                guard !Task.isCancelled else { break }
                await self?.timerFired()
            }
        }
    }

    private func timerFired() async {
        guard !systemEvents.suspended else { return }
        await refresh(reason: .timer)
    }

    /// Открытие панели: одно обновление, если данные устарели (stale) или отсутствуют.
    public func panelOpened() async {
        let now = clock.now()
        let stale = cards.contains { card in
            guard card.isConnected else { return false }
            guard let snapshot = card.snapshot else { return true }
            return now.timeIntervalSince(snapshot.fetchedAt) > TimeInterval(settings.staleSeconds)
        }
        if stale { await refresh(reason: .panelOpened) }
        else if !systemEvents.suspended { await customServices.refreshAll() }
    }

    // MARK: - Подключение

    /// Общий путь регистрации: новое поколение очищает старое состояние (§3).
    private func register(_ connection: ConnectionRecord) async {
        await restorationTask?.value
        let provider = connection.id.provider
        if let index = cards.firstIndex(where: { $0.provider == provider }) {
            cards[index].connection = connection
            cards[index].lastError = nil
            cards[index].snapshot = nil
        }
        await repository.registerConnection(connection)
        await coordinator.setConnection(connection)
        alertStore.reset(provider: provider)
        persistAlerts()
        await persistState()
    }

    /// Подключение OpenRouter: ключ → Keychain, из формы стирается.
    public func connectOpenRouter() throws {
        let key = pendingOpenRouterKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        let connection = ConnectionRecord(
            id: ConnectionID(provider: .openrouter, generation: UUID()),
            source: .manualKey, verifiedIdentityHash: nil)
        try vault.save(secret: Data(key.utf8), account: KeychainVault.account(for: connection))
        pendingOpenRouterKey = ""
        Task { await register(connection); await refreshOne(.openrouter) }
    }

    /// Подключение Kimi: ручной ключ ИЛИ read-only CLI token.
    public func connectKimi() throws {
        let key = pendingKimiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let reader = KimiCredentialReader()
        if !key.isEmpty {
            let connection = ConnectionRecord(
                id: ConnectionID(provider: .kimi, generation: UUID()),
                source: .manualKey, verifiedIdentityHash: nil)
            try vault.save(secret: Data(key.utf8), account: KeychainVault.account(for: connection))
            pendingKimiKey = ""
            Task { await register(connection); await refreshOne(.kimi) }
        } else {
            // CLI: проверяем наличие токена до регистрации подключения.
            _ = try reader.readCLIForTest(interaction: .userInitiated)
            let connection = ConnectionRecord(
                id: ConnectionID(provider: .kimi, generation: UUID()),
                source: .kimiCLI, verifiedIdentityHash: nil)
            Task { await register(connection); await refreshOne(.kimi) }
        }
    }

    /// Подключение Z.ai: ключ международного персонального плана.
    public func connectZai() throws {
        let key = pendingZaiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        let connection = ConnectionRecord(
            id: ConnectionID(provider: .zai, generation: UUID()),
            source: .manualKey, verifiedIdentityHash: nil)
        try vault.save(secret: Data(key.utf8), account: KeychainVault.account(for: connection))
        pendingZaiKey = ""
        Task { await register(connection); await refreshOne(.zai) }
    }

    /// Подключение Claude: read-only чтение локального входа (нажатие = согласие).
    public func connectClaude() throws {
        let reader = ClaudeCredentialReader()
        _ = try reader.readForTest(interaction: .userInitiated)
        let connection = ConnectionRecord(
            id: ConnectionID(provider: .claude, generation: UUID()),
            source: .claudeCLI, verifiedIdentityHash: nil)
        Task { await register(connection); await refreshOne(.claude) }
    }

    /// Подключение Codex: изолированный login-flow через CodexLoginController.
    /// Завершение входа наблюдается моделью, независимо от существования формы.
    public func finishCodexConnect() {
        guard !registeringCodex else { return }
        registeringCodex = true
        Task {
            await restorationTask?.value
            defer { registeringCodex = false }
            guard codexLogin.state == .completed,
                  cards.first(where: { $0.provider == .codex })?.connection == nil else { return }
            let connection = ConnectionRecord(
                id: ConnectionID(provider: .codex, generation: UUID()),
                source: .codexIsolatedLogin, verifiedIdentityHash: nil)
            await register(connection)
            await refreshOne(.codex)
        }
    }

    public func disconnect(_ provider: ProviderID) async {
        await restorationTask?.value
        guard let index = cards.firstIndex(where: { $0.provider == provider }),
              let connection = cards[index].connection else { return }
        // Удаляем только СВОЙ Keychain item; источники CLI не файловые.
        if connection.source == .manualKey {
            try? vault.delete(account: KeychainVault.account(for: connection))
        }
        // Codex: logout собственного изолированного входа.
        if provider == .codex {
            Task { await codexLogin.disconnect() }
        }
        // Отозвать pending-уведомления провайдера.
        let pendingIDs = alertStore.outbox.pending
            .filter { $0.provider == provider }.map(\.id)
        notifications.removePending(ids: pendingIDs)
        cards[index].connection = nil
        cards[index].snapshot = nil
        cards[index].lastError = nil
        cards[index].isRefreshing = false
        do {
            await repository.disconnect(provider)
            await coordinator.removeConnection(provider)
            alertStore.reset(provider: provider)
            persistAlerts()
            await persistState()
        }
    }

    // MARK: - Обновление

    /// Обновить все подключённые через координатор (backoff/Retry-After уважаются).
    public func refresh(reason: RefreshReason = .manual) async {
        let ids = cards.filter { $0.isConnected }.map(\.provider)
        guard !ids.isEmpty else {
            if !systemEvents.suspended { await customServices.refreshAll(force: reason == .manual) }
            return
        }
        for index in cards.indices where cards[index].isConnected {
            cards[index].isRefreshing = true
        }
        _ = await coordinator.request(providers: ids, reason: reason) { [weak self] update in
            await self?.apply(update)
        }
        for index in cards.indices { cards[index].isRefreshing = false }
        await persistState()
        await drainOutbox()
        if !systemEvents.suspended { await customServices.refreshAll(force: reason == .manual) }
    }

    /// Обновление одного провайдера.
    public func refreshOne(_ provider: ProviderID) async {
        guard let index = cards.firstIndex(where: { $0.provider == provider }),
              cards[index].connection != nil else { return }
        cards[index].isRefreshing = true
        _ = await coordinator.request(providers: [provider], reason: .manual) { [weak self] update in
            await self?.apply(update)
        }
        if let index = cards.firstIndex(where: { $0.provider == provider }) {
            cards[index].isRefreshing = false
        }
        await persistState()
    }

    /// Применить результат координатора: repository → UI → уведомления.
    private func apply(_ update: ProviderUpdate) async {
        let provider = update.connection.provider
        guard let index = cards.firstIndex(where: { $0.provider == provider }) else { return }
        // Поздний результат устаревшего поколения не применяется.
        guard cards[index].connection?.id == update.connection else { return }
        cards[index].isRefreshing = false
        switch update.result {
        case .success(let snapshot):
            do {
                try await repository.accept(snapshot: snapshot)
                guard cards[index].connection?.id == update.connection else { return }
                cards[index].snapshot = snapshot
                cards[index].lastError = nil
                SafeLogger.record(.refreshCompleted(provider: provider))
                await processAlerts(for: snapshot)
            } catch {
                SafeLogger.record(.refreshFailed(provider: provider, code: .invalidData))
            }
        case .failure(let error):
            await repository.recordFailure(connection: update.connection, error: error)
            guard cards[index].connection?.id == update.connection else { return }
            // Ошибка не стирает сохранённый снимок (план Task 13, шаг 3).
            cards[index].lastError = error
            SafeLogger.record(.refreshFailed(provider: provider, code: error))
        }
    }

    // MARK: - Уведомления

    /// Включение уведомлений: системное разрешение запрашивается только здесь,
    /// по явному действию пользователя (спецификация §8).
    public func setNotificationsEnabled(_ enabled: Bool) async {
        await restorationTask?.value
        if enabled {
            let granted = await notifications.requestPermission()
            alertStore.permissionRequested = true
            notificationsEnabled = granted
            notificationsDenied = !granted
        } else {
            notificationsEnabled = false
            notifications.removePending(ids: alertStore.outbox.pendingIDs)
            alertStore.outbox.removeAll { _ in true }
        }
        alertStore.notificationsEnabled = notificationsEnabled
        persistAlerts()
        if enabled { await drainOutbox() }
    }

    public func setAlertPreference(provider: ProviderID, warnings: Bool, recovery: Bool) {
        let preference = AlertPreference(warnings: warnings, recovery: recovery)
        alertPreferences[provider] = preference
        if alertStore.preferences == nil { alertStore.preferences = [:] }
        alertStore.preferences?[provider.rawValue] = preference
        // Pending мог быть сформирован с прежними категориями, поэтому не replay.
        let ids = alertStore.outbox.pending.filter { $0.provider == provider }.map(\.id)
        notifications.removePending(ids: ids)
        alertStore.outbox.removeAll { $0.provider == provider }
        persistAlerts()
    }

    /// Оценка свежего снимка: денежный порог + квотные пороги; эпизоды персистентны.
    func evaluate(snapshot: UsageSnapshot) -> [AlertEvent] {
        let now = clock.now()
        guard SnapshotPolicy.isFresh(fetchedAt: snapshot.fetchedAt, observedAt: snapshot.observedAt,
                                     lastRefreshFailed: false, resetAt: nil, now: now) else { return [] }
        var events: [AlertEvent] = []
        let connectionID = snapshot.connection
        let preference = alertPreferences[connectionID.provider] ?? AlertPreference()

        if let balance = snapshot.balanceUSD {
            let key = connectionID.provider.rawValue
            var episode = alertStore.balanceEpisodes[key] ?? BalanceEpisode()
            if BalanceAlertReducer.observe(
                balance: balance, validFresh: true,
                threshold: settings.openRouterThresholdUSD, state: &episode) != nil, preference.warnings {
                events.append(makeEvent(
                    connection: connectionID, suffix: "balance:usd3",
                    provider: .openrouter, title: "OpenRouter",
                    body: "Баланс ниже \(ValueFormatting.usd(settings.openRouterThresholdUSD, threshold: settings.openRouterThresholdUSD))"))
            }
            alertStore.balanceEpisodes[key] = episode
        }

        for quota in snapshot.quotas {
            guard SnapshotPolicy.isFresh(fetchedAt: snapshot.fetchedAt, observedAt: snapshot.observedAt,
                                         lastRefreshFailed: false, resetAt: quota.resetsAt, now: now) else { continue }
            guard let percent = quota.value.percent else { continue }
            let key = "\(connectionID.provider.rawValue):\(quota.id)"
            var episode = alertStore.quotaEpisodes[key] ?? QuotaEpisode()
            let previousEpisode = episode
            let alert = QuotaAlertReducer.observe(
                remainingPercent: Double(NSDecimalNumber(decimal: percent).doubleValue),
                state: &episode)
            if case .threshold = alert, !alertStore.notificationsEnabled || !preference.warnings {
                // Наблюдение порога не равно предупреждению пользователю.
                // Сохраняем прежний факт warning/recovery, но оставляем перевзвод порогов.
                episode.hadWarning = previousEpisode.hadWarning
                episode.isRecovered = previousEpisode.isRecovered
            }
            alertStore.quotaEpisodes[key] = episode
            switch alert {
            case .threshold(let threshold):
                guard preference.warnings else { continue }
                let percentInt = Int(NSDecimalNumber(decimal: percent).intValue)
                events.append(makeEvent(
                    connection: connectionID, suffix: "\(quota.id):t\(threshold)",
                    provider: connectionID.provider, title: connectionID.provider.displayName,
                    body: "\(quota.title): остаток \(percentInt)%"))
            case .recovered:
                guard preference.recovery else { continue }
                events.append(makeEvent(
                    connection: connectionID, suffix: "\(quota.id):recovery",
                    provider: connectionID.provider, title: connectionID.provider.displayName,
                    body: "\(quota.title): восстановление подтверждено, остаток \(NSDecimalNumber(decimal: percent).intValue)%"))
            case nil:
                break
            }
        }
        guard events.count > 1 else { return events }
        return [makeEvent(connection: connectionID, suffix: "snapshot", provider: connectionID.provider,
                          title: connectionID.provider.displayName,
                          body: events.map(\.body).joined(separator: "\n"))]
    }

    private func makeEvent(
        connection: ConnectionID, suffix: String, provider: ProviderID, title: String, body: String
    ) -> AlertEvent {
        return AlertEvent(
            id: "\(connection.generation.uuidString):\(suffix):\(UUID().uuidString)",
            provider: provider, title: title, body: body)
    }

    /// События → outbox → persist → доставка (только при включённых уведомлениях
    /// и системном разрешении). Недоставленные остаются в outbox до следующего цикла.
    private func processAlerts(for snapshot: UsageSnapshot) async {
        let events = evaluate(snapshot: snapshot)
        if alertStore.notificationsEnabled {
            for event in events { alertStore.outbox.enqueue(event) }
        }
        // Эпизод и его событие сохраняются одной транзакцией, даже без нового alert:
        // rearm/recovery observations должны переживать рестарт.
        guard persistAlerts() else { return }
        await drainOutbox()
    }

    private func drainOutbox() async {
        guard !drainingOutbox, alertStore.notificationsEnabled else { return }
        drainingOutbox = true
        defer { drainingOutbox = false }
        guard await notifications.authorizationGranted() else { return }
        let known = await notifications.knownEventIDs()
        for id in known { alertStore.outbox.markDelivered(id: id) }
        guard persistAlerts() else { return }
        while alertStore.notificationsEnabled, let event = alertStore.outbox.pending.first {
            do {
                try await notifications.deliver(event)
                alertStore.outbox.markDelivered(id: event.id)
                guard persistAlerts() else { return }
            } catch {
                SafeLogger.record(.refreshFailed(provider: event.provider, code: .network))
                break
            }
        }
    }

    // MARK: - Персистентность

    private func persistState() async {
        let envelope = await repository.export()
        do {
            try stateFile.write(envelope)
            stateWriteFailed = false
            updateStorageError()
        } catch {
            SafeLogger.record(.persistStateFailed)
            stateWriteFailed = true
            updateStorageError()
        }
    }

    @discardableResult
    private func persistAlerts() -> Bool {
        do {
            try alertFile.write(alertStore)
            alertWriteFailed = false
            updateStorageError()
            return true
        } catch {
            SafeLogger.record(.persistAlertsFailed)
            alertWriteFailed = true
            updateStorageError()
            return false
        }
    }

    private func updateStorageError() {
        storageError = stateWriteFailed || alertWriteFailed
            ? "Не удалось сохранить настройки или данные. Изменения могут потеряться после выхода. Проверьте свободное место и доступ к папке приложения."
            : nil
    }

    // MARK: - Завершение

    /// Остановка фоновых задач и helper-процессов (выход приложения).
    public func shutdown() {
        timerTask?.cancel()
        systemEvents.stop()
        Task { await codexServer.stop() }
    }
}
