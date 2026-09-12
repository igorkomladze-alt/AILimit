import Foundation
import UserNotifications
import AILimitsCore

/// Контракт доставки уведомлений (инъекция для тестов AppModel).
public protocol NotificationDelivering: Sendable {
    /// Запросить разрешение — по явному действию пользователя, не в фоне.
    @MainActor func requestPermission() async -> Bool
    /// Текущее системное разрешение (без запроса).
    func authorizationGranted() async -> Bool
    /// Доставить событие. ID используется для дедупликации на стороне системы.
    func deliver(_ event: AlertEvent) async throws
    /// Известные системе ID (pending + delivered) — сверка при старте.
    func knownEventIDs() async -> Set<String>
    /// Удалить pending-уведомления (смена/удаление подключения).
    func removePending(ids: [String])
}

/// Task 7, шаг 5: системная доставка через UNUserNotificationCenter.
/// Событие передаётся ТОЛЬКО после успешной записи outbox (вызывающая сторона).
public struct MacNotificationService: NotificationDelivering {
    public init() {}

    /// Запросить разрешение — по явному действию пользователя, не в фоне каждые 5 минут.
    @MainActor
    public func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// Фактическое системное разрешение без повторного диалога.
    public func authorizationGranted() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
    }

    /// Доставить событие. ID используется для дедупликации на стороне системы.
    public func deliver(_ event: AlertEvent) async throws {
        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = event.body
        let request = UNNotificationRequest(
            identifier: event.id,
            content: content,
            trigger: nil // немедленно
        )
        try await UNUserNotificationCenter.current().add(request)
    }

    /// Известные системе ID (pending + delivered) — сверка при старте,
    /// чтобы не создавать повторное событие из сохранённого снимка.
    public func knownEventIDs() async -> Set<String> {
        var ids = Set<String>()
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        ids.formUnion(pending.map(\.identifier))
        let delivered = await center.deliveredNotifications()
        ids.formUnion(delivered.map(\.request.identifier))
        return ids
    }

    /// Удалить pending-уведомления старого поколения (смена подключения).
    public func removePending(ids: [String]) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }
}
