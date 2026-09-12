import Foundation
import ServiceManagement

/// Task 13, шаг 5: автозапуск через SMAppService.mainApp.
/// Первоначально выключен; состояние сохраняется только после фактического
/// результата register/unregister. requiresApproval показывается как требующее
/// действия в Системных настройках. Параллельный LaunchAgent не создаётся.
@MainActor
public final class LoginItemController: ObservableObject {
    /// Фактический статус системы.
    @Published public private(set) var status: SMAppService.Status
    /// Требуется ли одобрение пользователя в Системных настройках.
    @Published public private(set) var needsApproval = false

    public init() {
        self.status = SMAppService.mainApp.status
        self.needsApproval = status == .requiresApproval
    }

    public var isEnabled: Bool { status == .enabled }

    /// Включить/выключить автозапуск. Ошибка пробрасывается вызывающей стороне,
    /// состояние не «оптимистично» не меняется.
    public func setEnabled(_ enabled: Bool) async throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try await SMAppService.mainApp.unregister()
        }
        let actual = SMAppService.mainApp.status
        self.status = actual
        self.needsApproval = actual == .requiresApproval
    }
}
