import SwiftUI
import AILimitsCore
import AILimitsMac

/// Кабинеты задаются приложением, а не ответами провайдеров.
enum CabinetLinks {
    static func url(for provider: ProviderID) -> URL {
        let address: String
        switch provider {
        case .claude: address = "https://claude.ai/settings/usage"
        case .codex: address = "https://chatgpt.com/codex/settings/usage"
        case .kimi: address = "https://www.kimi.com/coding"
        case .zai: address = "https://z.ai/billing"
        case .openrouter: address = "https://openrouter.ai/credits"
        }
        return URL(string: address)!
    }
}

struct PanelView: View {
    @ObservedObject var model: AppModel
    @State private var expanded: ProviderID?
    @AppStorage("ailimits.appearance") private var appearance = "system"
    var showsFooter = true

    private var visibleCards: [AppModel.CardState] {
        model.cards.filter { model.showDisconnected || $0.isConnected }
    }
    private var connectedCount: Int { model.cards.filter(\.isConnected).count }
    private var refreshing: Bool { model.cards.contains(where: \.isRefreshing) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("AI Limits").font(.title2.weight(.semibold))
                    Text(connectedCount == 0 ? "Ваши сервисы — в одном месте" : "Остатки лимитов · обновление каждые 5 мин")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(connectedCount) / 5")
                    .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                    .accessibilityLabel("Подключено сервисов: \(connectedCount) из 5")
            }
            .padding(20)
            Divider()
            if let message = model.storageError {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(spacing: 10) {
                    if !model.isRestored {
                        ProgressView("Восстанавливаем подключения…").padding()
                    } else if visibleCards.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "slider.horizontal.3").font(.largeTitle).foregroundStyle(.secondary)
                            Text("Сервисы скрыты").font(.headline)
                            Text("Покажите отключённые сервисы, чтобы добавить первое подключение.")
                                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            Button("Показать сервисы") { model.showDisconnected = true }
                                .buttonStyle(.bordered)
                        }.padding(24)
                    } else {
                        ForEach(visibleCards) { card in
                            ProviderCard(card: card, model: model, expanded: Binding(
                                get: { expanded == card.provider },
                                set: { expanded = $0 ? card.provider : nil }))
                        }
                    }
                }.padding(14)
            }
            .frame(maxHeight: 520)
            if showsFooter {
                Divider()
                HStack(spacing: 16) {
                    Button {
                        Task { await model.refresh(reason: .manual) }
                    } label: {
                        Label(refreshing ? "Обновление…" : "Обновить", systemImage: "arrow.clockwise")
                    }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(!model.isRestored || connectedCount == 0 || refreshing)
                    Spacer(minLength: 0)
                    SettingsLink { Image(systemName: "gearshape").font(.body) }
                        .help("Настройки").accessibilityLabel("Настройки")
                    Button {
                        model.shutdown()
                        NSApp.terminate(nil)
                    } label: { Image(systemName: "power").font(.body) }
                        .help("Завершить AI Limits").accessibilityLabel("Завершить AI Limits")
                }
                .buttonStyle(.borderless).font(.callout)
                .padding(.horizontal, 20).padding(.vertical, 14)
            }
        }
        .frame(width: 400)
        .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        .task(id: model.isRestored) {
            if model.isRestored { await model.panelOpened() }
        }
    }
}

struct ProviderCard: View {
    let card: AppModel.CardState
    @ObservedObject var model: AppModel
    @Binding var expanded: Bool
    @State private var errorMessage: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 12) {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 10) {
                        ServiceLogo(provider: card.provider, size: 18)
                        Text(card.provider.displayName).font(.headline)
                        Spacer()
                        if card.isRefreshing { ProgressView().controlSize(.small) }
                        Text(status(at: context.date)).font(.caption)
                            .foregroundStyle(statusColor(at: context.date))
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(card.provider.displayName), \(status(at: context.date))")
                .accessibilityValue(expanded ? "Развёрнуто" : "Свёрнуто")
                .accessibilityHint(card.isConnected ? "Показать подробности подключения" : "Показать способы подключения")

                if let snapshot = card.snapshot {
                    snapshotView(snapshot, now: context.date)
                } else if card.isConnected {
                    Text(card.lastError.map(errorHint) ?? "Получаем данные сервиса…")
                        .font(.callout).foregroundStyle(.secondary)
                } else if !expanded {
                    Text("Подключить сервис")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if expanded {
                    Divider()
                    if card.isConnected { details } else { connectForm }
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.red)
                }
            }
            .padding(14)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.08)))
        }
        .accessibilityElement(children: .contain)
    }

    private func isFresh(at now: Date) -> Bool {
        guard let snapshot = card.snapshot else { return false }
        return SnapshotPolicy.isFresh(fetchedAt: snapshot.fetchedAt, observedAt: snapshot.observedAt,
            lastRefreshFailed: card.lastError != nil,
            resetAt: snapshot.quotas.compactMap(\.resetsAt).min(), now: now)
    }

    private func status(at now: Date) -> String {
        if card.isRefreshing { return "Обновление" }
        if !card.isConnected { return "Не подключён" }
        if card.lastError != nil { return "Нужна проверка" }
        if card.snapshot == nil { return "Ожидание" }
        return isFresh(at: now) ? "Актуально" : "Устарело"
    }

    private func statusColor(at now: Date) -> Color {
        if card.lastError != nil || (card.snapshot != nil && !isFresh(at: now)) { return .orange }
        return .secondary
    }

    @ViewBuilder
    private func snapshotView(_ snapshot: UsageSnapshot, now: Date) -> some View {
        if let balance = snapshot.balanceUSD {
            HStack(alignment: .firstTextBaseline) {
                Text(ValueFormatting.usd(balance, threshold: 3))
                    .font(.title2.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(balance < 3 ? Color.orange : .primary)
                Spacer()
                Text("Баланс USD").font(.caption).foregroundStyle(.secondary)
            }
        }
        ForEach(displayedQuotas(snapshot)) { quota in
            quotaRow(quota, now: now)
        }
        if snapshot.quotas.isEmpty && snapshot.balanceUSD == nil {
            Text("Сервис пока не вернул лимиты").font(.callout).foregroundStyle(.secondary)
        }
        if !expanded && snapshot.quotas.count > displayedQuotas(snapshot).count {
            Button("Другие лимиты: \(snapshot.quotas.count - displayedQuotas(snapshot).count)") { expanded = true }
                .buttonStyle(.borderless).font(.caption)
        }
        HStack(spacing: 4) {
            Image(systemName: isFresh(at: now) ? "clock" : "clock.badge.exclamationmark")
            Text("Обновлено \(ValueFormatting.ageLabel(since: snapshot.fetchedAt, now: now))")
        }.font(.caption2).foregroundStyle(.secondary)
        if let error = card.lastError {
            Label(errorHint(error), systemImage: "exclamationmark.circle")
                .font(.caption).foregroundStyle(.orange)
        }
    }

    private func displayedQuotas(_ snapshot: UsageSnapshot) -> [UsageQuota] {
        if expanded { return snapshot.quotas }
        if card.provider == .codex {
            let main = snapshot.quotas.filter { $0.scope == "codex" || $0.id.hasPrefix("codex.codex.") }
            if !main.isEmpty { return main }
        }
        return Array(snapshot.quotas.prefix(2))
    }

    private func quotaRow(_ quota: UsageQuota, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(quota.title).font(.callout).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if let percent = quota.value.percent {
                    Text("\(NSDecimalNumber(decimal: percent).intValue)% осталось")
                        .font(.callout.weight(.medium)).monospacedDigit()
                } else {
                    Text(quota.value == .unlimited ? "Без лимита" : "Нет данных")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let percent = quota.value.percent {
                ProgressView(value: NSDecimalNumber(decimal: percent).doubleValue, total: 100)
                    .tint(percent <= 5 ? .red : percent <= 20 ? .orange : .accentColor)
                    .accessibilityLabel("Остаток: \(quota.title)")
                    .accessibilityValue("\(NSDecimalNumber(decimal: percent).intValue) процентов")
            }
            HStack(alignment: .top) {
                if let window = ValueFormatting.windowLabel(windowSeconds: quota.windowSeconds) {
                    Text(window)
                }
                Spacer(minLength: 4)
                Text(ValueFormatting.resetLabel(resetAt: quota.resetsAt, now: now, confirmed: false))
                    .multilineTextAlignment(.trailing)
            }.font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            if card.provider == .codex {
                Text("Часы и дни — периоды учёта, а не режим работы. Каждая группа имеет свой лимит. Технический код показан, если сервис не передал название.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(sourceLabel).font(.caption).foregroundStyle(.secondary)
            Text(card.connection?.verifiedIdentityHash == nil
                 ? "Сервис не подтвердил личность аккаунта."
                 : "Принадлежность аккаунту подтверждена.")
                .font(.caption2).foregroundStyle(.secondary)
            HStack {
                Link(destination: CabinetLinks.url(for: card.provider)) {
                    Label("Кабинет", systemImage: "arrow.up.right.square")
                }
                Spacer()
                Button("Отключить", role: .destructive) {
                    Task { await model.disconnect(card.provider) }
                }
            }.buttonStyle(.borderless).font(.callout)
        }
    }

    private var sourceLabel: String {
        switch card.connection?.source {
        case .manualKey: "Ключ сохранён в Связке ключей Mac"
        case .kimiCLI: "Локальный вход Kimi CLI · только чтение"
        case .claudeCLI: "Локальный вход Claude Code · только чтение"
        case .codexIsolatedLogin: "Отдельный вход Codex для AI Limits"
        case nil: ""
        }
    }

    @ViewBuilder
    private var connectForm: some View {
        switch card.provider {
        case .openrouter:
            KeyForm(placeholder: "Management Key", hint: "Нужен Management Key OpenRouter. Приложение только читает баланс, но сам ключ имеет более широкие права.",
                    text: $model.pendingOpenRouterKey, connect: { try model.connectOpenRouter() })
        case .kimi:
            VStack(alignment: .leading, spacing: 10) {
                KeyForm(placeholder: "Ключ Kimi Code", hint: "Ключ из консоли Kimi Code, не Moonshot API.",
                        text: $model.pendingKimiKey, connect: { try model.connectKimi() })
                Text("Или разрешите чтение действующего входа Kimi CLI. Файлы CLI не изменяются.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Использовать вход Kimi CLI") {
                    errorMessage = nil
                    do { try model.connectKimi() } catch { errorMessage = "Не удалось прочитать вход Kimi CLI. Войдите в CLI или используйте ключ." }
                }.disabled(!model.pendingKimiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        case .zai:
            KeyForm(placeholder: "Ключ Z.ai", hint: "Международный персональный Coding Plan (api.z.ai). BigModel CN не поддерживается.",
                    text: $model.pendingZaiKey, connect: { try model.connectZai() })
        case .claude:
            VStack(alignment: .leading, spacing: 10) {
                Text("Разрешите чтение локального входа Claude Code. Приложение не изменяет и не продлевает этот вход.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Разрешить и подключить") {
                    errorMessage = nil
                    do { try model.connectClaude() } catch { errorMessage = "Подходящий вход не найден. Сначала войдите в Claude Code и повторите." }
                }.buttonStyle(.borderedProminent)
            }
        case .codex:
            CodexConnectionForm(model: model, login: model.codexLogin)
        }
    }

    private func errorHint(_ error: ProviderError) -> String {
        switch error {
        case .authenticationRequired: "Вход истёк или ключ не принят. Отключите сервис и подключите снова."
        case .permissionDenied: "Недостаточно прав. Проверьте тип ключа и доступ к подписке."
        case .rateLimited(let until): "Сервис ограничил запросы. Следующая попытка после \(until.formatted(date: .omitted, time: .shortened))."
        case .network: "Нет связи с сервисом. Проверьте интернет и повторите."
        case .timeout: "Сервис не ответил вовремя. Повторите обновление."
        case .keychainLocked: "Разблокируйте Связку ключей Mac и повторите."
        case .dependencyMissing: "Установите официальный Codex CLI, затем повторите вход."
        case .incompatibleSchema: "Формат ответа сервиса изменился. Требуется обновление приложения."
        case .invalidData: "Сервис вернул некорректные данные. Повторите позже."
        case .server(let status): "Сервис временно недоступен (\(status)). Повторите позже."
        case .disconnected: "Подключение прервано. Подключите сервис снова."
        case .consentRequired: "Разрешите чтение источника при подключении."
        case .unsupportedSource: "Этот источник не поддерживается. Выберите другой способ подключения."
        case .cancelled: "Обновление отменено."
        }
    }
}

struct CodexConnectionForm: View {
    @ObservedObject var model: AppModel
    @ObservedObject var login: CodexLoginController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Отдельный вход через официальный Codex CLI. Действующий вход других приложений сохраняется.")
                .font(.callout).foregroundStyle(.secondary)
            switch login.state {
            case .idle:
                Button("Войти через Codex") { login.begin() }.buttonStyle(.borderedProminent)
            case .inProgress(let url, let code):
                HStack {
                    ProgressView().controlSize(.small)
                    Text(url.isEmpty ? "Подготавливаем вход…" : "Завершите вход в браузере")
                        .font(.callout)
                }
                if !url.isEmpty {
                    if let destination = CodexLoginController.safeLoginURL(url) {
                        Link("Открыть страницу входа", destination: destination)
                            .buttonStyle(.borderedProminent)
                    }
                }
                if let code, !code.isEmpty { Text("Код: \(code)").font(.callout.monospaced()).textSelection(.enabled) }
                Button("Отменить вход") { login.cancel() }
            case .completed:
                ProgressView("Подключаем Codex…").font(.callout)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
                Button("Повторить вход") { login.begin() }
            }
        }
    }
}

struct KeyForm: View {
    let placeholder: String
    let hint: String
    @Binding var text: String
    let connect: () throws -> Void
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(hint).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SecureField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder).accessibilityLabel(placeholder)
                .onSubmit { submit() }
            HStack {
                Label("В Связке ключей Mac", systemImage: "lock")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Подключить") { submit() }
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.red) }
        }
    }

    private func submit() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        errorMessage = nil
        do { try connect() } catch { errorMessage = "Не удалось сохранить ключ. Проверьте доступ к Связке ключей Mac." }
    }
}
