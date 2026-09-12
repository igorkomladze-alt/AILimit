import SwiftUI
import AILimitsCore
import AILimitsMac

struct CustomServicesSettingsView: View {
    @ObservedObject var store: CustomServiceStore
    @State private var adding = false
    @State private var editing: CustomServiceDefinition?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Свои сервисы").font(.title3.weight(.semibold))
                Spacer()
                Button { adding = true } label: { Label("Добавить сервис", systemImage: "plus") }
            }
            Text("Подключайте JSON API статистики по HTTPS. Поддерживаются GET-запросы с API-ключом; вход через OAuth и сайты без API требуют отдельной интеграции.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            ScrollView {
                VStack(spacing: 8) {
                    if store.entries.isEmpty {
                        ContentUnavailableView("Пока нет своих сервисов", systemImage: "network",
                            description: Text("Добавьте DeepSeek по шаблону или настройте другой API."))
                    }
                    ForEach(store.entries) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(entry.definition.name).font(.headline)
                                Spacer()
                                if entry.isRefreshing { ProgressView().controlSize(.small) }
                                Button("Изменить") { editing = entry.definition }
                                Button("Удалить", role: .destructive) {
                                    do { try store.delete(id: entry.definition.id) }
                                    catch { self.error = "Не удалось удалить подключение. Проверьте доступ к хранилищу." }
                                }
                            }
                            Text(entry.definition.endpoint.host ?? "").font(.caption).foregroundStyle(.secondary)
                            if let snapshot = entry.snapshot {
                                ForEach(snapshot.metrics) { value in
                                    HStack {
                                        Text(value.metric.name)
                                        Spacer()
                                        Text(CustomMetricPresentation.text(value)).monospacedDigit()
                                    }.font(.callout)
                                }
                                Text("Обновлено \(ValueFormatting.ageLabel(since: snapshot.observedAt, now: .now))")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            if let message = entry.error { Text(message).font(.caption).foregroundStyle(.orange) }
                        }.padding(10).background(.quinary, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            Text("Свои сервисы пока показывают статистику без пороговых уведомлений.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(16)
        .sheet(isPresented: $adding) { CustomServiceEditor(store: store) }
        .sheet(item: $editing) { definition in CustomServiceEditor(store: store, existing: definition) }
    }
}

struct CustomServiceEditor: View {
    @ObservedObject var store: CustomServiceStore
    @Environment(\.dismiss) private var dismiss
    private let existingID: UUID?
    @State private var name: String
    @State private var endpoint: String
    @State private var auth: CustomServiceAuth
    @State private var metrics: [CustomMetric]
    @State private var key = ""
    @State private var template = "custom"
    @State private var error: String?
    @State private var saving = false

    init(store: CustomServiceStore, existing: CustomServiceDefinition? = nil) {
        self.store = store
        self.existingID = existing?.id
        _name = State(initialValue: existing?.name ?? "")
        _endpoint = State(initialValue: existing?.endpoint.absoluteString ?? "")
        _auth = State(initialValue: existing?.auth ?? .bearer)
        _metrics = State(initialValue: existing?.metrics ?? [CustomMetric(name: "Остаток", valuePath: "data.remaining_percent", kind: .remainingPercent)])
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(existingID == nil ? "Добавить сервис" : "Изменить сервис").font(.title3.weight(.semibold))
                Spacer()
            }.padding(18)
            Form {
                if existingID == nil {
                    Picker("Шаблон", selection: $template) {
                        Text("Свой JSON API").tag("custom")
                        Text("DeepSeek — баланс API").tag("deepseek")
                    }
                    .onChange(of: template) { _, value in
                        if value == "deepseek" {
                            name = "DeepSeek"
                            endpoint = "https://api.deepseek.com/user/balance"
                            auth = .bearer
                            metrics = [CustomMetric(name: "Баланс", valuePath: "balance_infos.0.total_balance",
                                kind: .balance, currencyPath: "balance_infos.0.currency")]
                        }
                    }
                }
                Section("Подключение") {
                    TextField("Название", text: $name)
                    TextField("HTTPS-адрес API", text: $endpoint, prompt: Text("https://api.example.com/usage"))
                        .textContentType(.URL)
                    Picker("Авторизация", selection: $auth) {
                        Text("Без ключа").tag(CustomServiceAuth.none)
                        Text("Bearer token").tag(CustomServiceAuth.bearer)
                        Text("X-API-Key").tag(CustomServiceAuth.apiKey)
                    }
                    if auth != .none {
                        SecureField(existingID == nil ? "API-ключ" : "Новый ключ (пусто — оставить прежний)", text: $key)
                    }
                    Text("Только GET-запрос. Ключ хранится в Связке ключей Mac и отправляется на указанный адрес. Не вставляйте секреты в URL или названия полей.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach($metrics) { $metric in
                    Section {
                        CustomMetricFields(metric: $metric)
                        if metrics.count > 1 {
                            Button("Убрать показатель", role: .destructive) { metrics.removeAll { $0.id == metric.id } }
                        }
                    } header: { Text("Показатель \((metrics.firstIndex(where: { $0.id == metric.id }) ?? 0) + 1)") }
                }
                if metrics.count < 8 {
                    Button { metrics.append(CustomMetric(name: "Остаток", valuePath: "", kind: .remainingPercent)) }
                    label: { Label("Добавить показатель", systemImage: "plus") }
                }
                Section {
                    Text("Пути из ответа JSON: data.remaining или balance_infos.0.total_balance. Цифра обозначает индекс массива. Приложение проверит запрос и поля перед сохранением; сырые ответы не сохраняются.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).disabled(saving)
            if let error {
                Text(error).font(.caption).foregroundStyle(.orange)
                    .padding(.horizontal, 18).padding(.vertical, 8).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if saving { ProgressView().controlSize(.small); Text("Проверяем API…").font(.caption) }
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button("Проверить и сохранить") { save() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || endpoint.isEmpty)
            }.padding(16)
        }
        .frame(width: 510, height: 650)
        .interactiveDismissDisabled(saving)
        .onDisappear { key = "" }
    }

    private func save() {
        error = nil
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            error = "Введите корректный HTTPS-адрес API."; return
        }
        let definition = CustomServiceDefinition(id: existingID ?? UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            endpoint: url, auth: auth, metrics: metrics)
        saving = true
        Task {
            do {
                try await store.save(definition: definition, key: key)
                key = ""
                dismiss()
            } catch {
                self.error = (error as? CustomServiceError)?.errorDescription
                    ?? "Не удалось подключить сервис. Проверьте адрес, ключ и пути JSON."
            }
            saving = false
        }
    }
}

private struct CustomMetricFields: View {
    @Binding var metric: CustomMetric
    var body: some View {
        TextField("Название показателя", text: $metric.name)
        Picker("Значение в API", selection: $metric.kind) {
            Text("Остаток в процентах").tag(CustomMetricKind.remainingPercent)
            Text("Израсходовано в процентах").tag(CustomMetricKind.usedPercent)
            Text("Денежный баланс").tag(CustomMetricKind.balance)
            Text("Остаток / общий лимит").tag(CustomMetricKind.remainingCounts)
            Text("Израсходовано / общий лимит").tag(CustomMetricKind.usedCounts)
        }
        TextField("Путь к значению", text: $metric.valuePath)
        if metric.kind == .remainingCounts || metric.kind == .usedCounts {
            TextField("Путь к общему лимиту", text: optional($metric.totalPath))
        }
        if metric.kind == .balance {
            TextField("Валюта (USD, CNY…)", text: optional($metric.currency))
            TextField("Или путь к валюте в JSON", text: optional($metric.currencyPath))
        } else {
            TextField("Период, часов (необязательно)", text: Binding(
                get: { metric.windowSeconds.map { String($0 / 3600) } ?? "" },
                set: { metric.windowSeconds = Double($0).map { $0 * 3600 } }))
        }
        TextField("Путь к дате сброса (необязательно)", text: optional($metric.resetPath))
        Text("Дата сброса: ISO 8601 или Unix-время в секундах.").font(.caption2).foregroundStyle(.secondary)
    }

    private func optional(_ binding: Binding<String?>) -> Binding<String> {
        Binding(get: { binding.wrappedValue ?? "" }, set: { binding.wrappedValue = $0.isEmpty ? nil : $0 })
    }
}

enum CustomMetricPresentation {
    static func percent(_ value: CustomMetricValue) -> Decimal? {
        switch value.metric.kind {
        case .remainingPercent: value.value
        case .usedPercent: 100 - value.value
        case .balance: nil
        case .remainingCounts: value.total.flatMap { $0 > 0 ? value.value / $0 * 100 : nil }
        case .usedCounts: value.total.flatMap { $0 > 0 ? (1 - value.value / $0) * 100 : nil }
        }
    }
    static func text(_ value: CustomMetricValue) -> String {
        if let percent = percent(value) { return "\(NSDecimalNumber(decimal: percent).intValue)%" }
        return "\(NSDecimalNumber(decimal: value.value).stringValue) \(value.currency ?? value.metric.currency ?? "")"
    }
}

struct CustomCompactCard: View {
    let entry: CustomServiceEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                if entry.definition.endpoint.host == "api.deepseek.com" {
                    Image("service-deepseek").resizable().scaledToFit().frame(width: 14, height: 14)
                } else { Image(systemName: "network").font(.system(size: 12)).foregroundStyle(.secondary) }
                Text(entry.definition.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer()
                if entry.isRefreshing { ProgressView().controlSize(.mini) }
                SettingsLink { Image(systemName: "ellipsis") }.buttonStyle(.borderless)
                    .help("Управление своими сервисами")
            }.frame(height: 18)
            if let snapshot = entry.snapshot {
                ForEach(snapshot.metrics.prefix(2)) { value in
                    VStack(spacing: 3) {
                        HStack {
                            Text(value.metric.name).lineLimit(1).foregroundStyle(.secondary)
                            Spacer()
                            Text(CustomMetricPresentation.text(value)).monospacedDigit().fontWeight(.semibold)
                        }.font(.system(size: 11))
                        if let percent = CustomMetricPresentation.percent(value) {
                            ProgressView(value: NSDecimalNumber(decimal: percent).doubleValue, total: 100)
                                .tint(percent <= 5 ? .red : percent <= 20 ? .orange : .accentColor)
                                .accessibilityLabel("\(value.metric.name): остаток")
                        }
                    }.frame(height: 26)
                }
                if snapshot.metrics.count > 2 {
                    SettingsLink { Text("Ещё показателей: \(snapshot.metrics.count - 2)") }.font(.system(size: 10))
                }
            } else { Text("Нет данных").font(.caption2).foregroundStyle(.secondary) }
            if entry.error != nil { Text("Ошибка обновления · подробнее в настройках").font(.system(size: 9)).foregroundStyle(.orange) }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 6))
    }
}
