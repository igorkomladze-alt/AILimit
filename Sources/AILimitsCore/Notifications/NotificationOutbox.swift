import Foundation

/// Task 7, шаг 5: durable событие уведомления с уникальным ID.
public struct AlertEvent: Codable, Equatable, Sendable {
    /// `connectionUUID:quotaStableID:ruleVersion:sequence`.
    public let id: String
    public let provider: ProviderID
    public let title: String
    public let body: String

    public init(id: String, provider: ProviderID, title: String, body: String) {
        self.id = id
        self.provider = provider
        self.title = title
        self.body = body
    }
}

/// Outbox: события ожидающие доставки. Хранится атомарно вместе с alert-state;
/// только после успешной записи событие передаётся в UNUserNotificationCenter.
public struct NotificationOutbox: Codable, Equatable, Sendable {
    public private(set) var pending: [AlertEvent] = []

    public init() {}

    public var pendingIDs: [String] { pending.map(\.id) }

    /// Поставить в очередь. Тот же ID не дублируется.
    public mutating func enqueue(_ event: AlertEvent) {
        guard !pending.contains(event) else { return }
        pending.append(event)
    }

    /// Пометить доставленным (после принятия системным API).
    public mutating func markDelivered(id: String) {
        pending.removeAll { $0.id == id }
    }

    /// Удалить ожидающие события по условию (смена/удаление подключения).
    public mutating func removeAll(where predicate: (AlertEvent) -> Bool) {
        pending.removeAll(where: predicate)
    }
}
