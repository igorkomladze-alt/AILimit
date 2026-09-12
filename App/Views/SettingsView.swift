import SwiftUI
import AILimitsCore
import AILimitsMac

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @AppStorage("ailimits.appearance") private var appearance = "system"

    var body: some View {
        TabView {
            PanelView(model: model, showsFooter: false)
                .tabItem { Label("Подключения", systemImage: "link") }
            CustomServicesSettingsView(store: model.customServices)
                .tabItem { Label("Свои сервисы", systemImage: "plus.circle") }
            GeneralSettingsView(model: model, loginItems: model.loginItems)
                .tabItem { Label("Общие", systemImage: "gearshape") }
        }
        .frame(width: 440, height: 580)
        .padding(12)
        .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var loginItems: LoginItemController
    @State private var loginError: String?
    @AppStorage("ailimits.appearance") private var appearance = "system"
    @State private var changingLogin = false
    @State private var changingNotifications = false

    var body: some View {
        Form {
            Section("Уведомления") {
                Toggle("Предупреждать о низком остатке", isOn: Binding(
                    get: { model.notificationsEnabled },
                    set: { enabled in
                        changingNotifications = true
                        Task {
                            await model.setNotificationsEnabled(enabled)
                            changingNotifications = false
                        }
                    }))
                    .disabled(changingNotifications)
                Text("Лимиты: 20% и 5%. Баланс OpenRouter: ниже $3. Уведомление о восстановлении приходит после проверки сервиса.")
                    .font(.caption).foregroundStyle(.secondary)
                if model.notificationsDenied {
                    Text("Если доступ отклонён, разрешите уведомления для AI Limits в Системных настройках → Уведомления.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("По сервисам") {
                ForEach(ProviderID.allCases.sorted { $0.displayOrder < $1.displayOrder }, id: \.self) { provider in
                    DisclosureGroup(provider.displayName) {
                        Toggle("Низкий остаток", isOn: Binding(
                            get: { model.alertPreferences[provider]?.warnings ?? true },
                            set: { value in
                                model.setAlertPreference(provider: provider, warnings: value,
                                    recovery: model.alertPreferences[provider]?.recovery ?? true)
                            }))
                        if provider != .openrouter {
                            Toggle("Восстановление лимита", isOn: Binding(
                                get: { model.alertPreferences[provider]?.recovery ?? true },
                                set: { value in
                                    model.setAlertPreference(provider: provider,
                                        warnings: model.alertPreferences[provider]?.warnings ?? true, recovery: value)
                                }))
                        }
                    }
                }
            }
            Section("Поведение") {
                Picker("Оформление", selection: $appearance) {
                    Text("Как в системе").tag("system")
                    Text("Светлое").tag("light")
                    Text("Тёмное").tag("dark")
                }
                Toggle("Запускать при входе в macOS", isOn: Binding(
                    get: { loginItems.isEnabled },
                    set: { enabled in
                        loginError = nil
                        changingLogin = true
                        Task {
                            do { try await loginItems.setEnabled(enabled) }
                            catch { loginError = "Не удалось изменить автозапуск. Проверьте Объекты входа в Системных настройках." }
                            changingLogin = false
                        }
                    }))
                    .disabled(changingLogin)
                if loginItems.needsApproval {
                    Text("Подтвердите автозапуск: Системные настройки → Основные → Объекты входа.")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.orange) }
                Toggle("Показывать отключённые сервисы", isOn: $model.showDisconnected)
                LabeledContent("Обновление", value: "Каждые 5 минут")
            }
            Section("Хранение данных") {
                Label("Ключи хранятся в Связке ключей Mac", systemImage: "lock.shield")
                Text("Приложение запрашивает статистику напрямую у сервисов. Снимки лимитов сохраняются только на этом Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}
