import SwiftUI
import AppKit
import AILimitsMac

/// Task 13, шаг 3: точка явной композиции приложения.
/// Один AppModel на процесс: панель, настройки и AppKitBridge используют один экземпляр.
@MainActor
enum AppComposition {
    static let model = AppModel()
}

@main
struct AILimitsApp: App {
    @NSApplicationDelegateAdaptor(AppKitBridge.self) private var bridge

    var body: some Scene {
        // Единственная точка интеграции: иконка без текста (§1).
        // MenuIdentity.visibleTitle == nil — тест Task 2 фиксирует это контрактно.
        MenuBarExtra {
            CompactPanelView(model: AppComposition.model)
        } label: {
            Image(systemName: MenuIdentity.symbol)
                .accessibilityLabel(MenuIdentity.accessibilityLabel)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: AppComposition.model)
        }
    }
}

/// AppKit-точка: onboarding при первом запуске и корректное завершение (Task 13, шаг 4).
@MainActor
final class AppKitBridge: NSObject, NSApplicationDelegate {
    private var onboardingWindow: NSWindow?
    private static let onboardingKey = "ailimits.onboardingShown"

    /// Первый запуск открывает окно подключений ДО первого клика по иконке.
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !UserDefaults.standard.bool(forKey: Self.onboardingKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.onboardingKey)
        showConnections(onboarding: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showConnections() }
        return true
    }

    private func showConnections(onboarding: Bool = false) {
        if let onboardingWindow {
            onboardingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let model = AppComposition.model
        let content = onboarding
            ? AnyView(PanelView(model: model))
            : AnyView(CompactPanelView(model: model))
        let controller = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: controller)
        window.title = onboarding ? "AI Limits — подключение сервисов" : "AI Limits"
        window.styleMask = [.titled, .closable]
        if onboarding { window.setContentSize(NSSize(width: 400, height: 640)) }
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow = window
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppComposition.model.shutdown()
    }

    /// Закрытие onboarding/настроек не завершает приложение (menubar-only).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
