import Foundation
import AILimitsCore

/// Task 14: структурированные безопасные логи.
/// render принимает ТОЛЬКО enum с фиксированными полями — сырой request/body/AuthLease
/// физически не может попасть в журнал.
public enum SafeLogEvent: Sendable {
    case refreshStarted(provider: ProviderID)
    case refreshFailed(provider: ProviderID, code: ProviderError)
    case refreshCompleted(provider: ProviderID)
    /// Ошибка записи state.json.
    case persistStateFailed
    /// Ошибка записи alerts.json.
    case persistAlertsFailed

    var provider: ProviderID? {
        switch self {
        case .refreshStarted(let p), .refreshFailed(let p, _), .refreshCompleted(let p): return p
        case .persistStateFailed, .persistAlertsFailed: return nil
        }
    }

    var kind: String {
        switch self {
        case .refreshStarted: return "started"
        case .refreshFailed: return "failed"
        case .refreshCompleted: return "completed"
        case .persistStateFailed: return "persist-state-failed"
        case .persistAlertsFailed: return "persist-alerts-failed"
        }
    }

    var codeName: String? {
        if case .refreshFailed(_, let code) = self { return String(describing: code) }
        return nil
    }
}

public enum SafeLogger {
    /// Фиксированное представление: провайдер + вид + код ошибки. Ничего больше.
    public static func render(_ event: SafeLogEvent) -> String {
        var parts = ["ailimits", event.kind]
        if let provider = event.provider { parts.append(provider.rawValue) }
        if let code = event.codeName { parts.append(code) }
        return parts.joined(separator: ":")
    }

    public static func record(_ event: SafeLogEvent) {
        // os_log без интерполяции произвольных строк.
        #if DEBUG
        NSLog("%{public}@", render(event))
        #endif
    }
}
