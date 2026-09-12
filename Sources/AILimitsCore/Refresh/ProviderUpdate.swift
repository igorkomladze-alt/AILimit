import Foundation

/// Task 6, шаг 4: обновление провайдера — результат с исходным поколением.
public struct ProviderUpdate: Sendable {
    public let connection: ConnectionID
    public let result: Result<UsageSnapshot, ProviderError>

    public init(connection: ConnectionID, result: Result<UsageSnapshot, ProviderError>) {
        self.connection = connection
        self.result = result
    }
}

/// Причина обновления (план Task 6).
public enum RefreshReason: String, Sendable {
    case timer
    case panelOpened
    case manual
    case wake
    case networkRestored
}
