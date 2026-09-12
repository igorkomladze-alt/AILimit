import SwiftUI
import AILimitsCore
import AILimitsMac

/// Меню требует явной высоты ScrollView: maxHeight не задаёт intrinsic size.
struct CompactPanelView: View {
    @ObservedObject var model: AppModel
    @AppStorage("ailimits.appearance") private var appearance = "system"
    @State private var expanded: Set<ProviderID> = []
    @State private var addingService = false

    private var cards: [AppModel.CardState] {
        model.cards.filter { $0.isConnected || model.showDisconnected }
    }

    private func quotas(_ card: AppModel.CardState) -> [UsageQuota] {
        guard let snapshot = card.snapshot else { return [] }
        if expanded.contains(card.provider) { return snapshot.quotas }
        if card.provider == .codex {
            let main = snapshot.quotas.filter { $0.scope == "codex" || $0.id.hasPrefix("codex.codex.") }
            if !main.isEmpty { return main }
        }
        return Array(snapshot.quotas.prefix(2))
    }

    private var contentHeight: CGFloat {
        let customEntries = model.customServices.entries
        guard !cards.isEmpty || !customEntries.isEmpty else { return 62 }
        var height: CGFloat = 0
        for entry in customEntries {
            let count = min(entry.snapshot?.metrics.count ?? 0, 2)
            height += 30 + CGFloat(max(1, count)) * 29
            if entry.error != nil { height += 16 }
            if (entry.snapshot?.metrics.count ?? 0) > 2 { height += 18 }
        }
        for card in cards {
            let count = quotas(card).count
            height += 26 + CGFloat(count) * 26
            if (card.snapshot?.quotas.count ?? 0) > count || expanded.contains(card.provider) {
                height += 16
            }
            if card.snapshot?.balanceUSD != nil { height += 20 }
            if card.isConnected && card.snapshot == nil { height += 28 }
            if card.lastError != nil && card.snapshot != nil { height += 28 }
        }
        let gaps = max(0, cards.count + customEntries.count - 1)
        return height + CGFloat(gaps) * 4
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                Text("AI Limits").font(.system(size: 12, weight: .medium))
                Spacer()
                Button {
                    Task { await model.refresh(reason: .manual) }
                } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(!model.isRestored || (!model.cards.contains(where: \.isConnected) && model.customServices.entries.isEmpty)
                              || model.cards.contains(where: \.isRefreshing)
                              || model.customServices.entries.contains(where: \.isRefreshing))
                    .help("Обновить лимиты").accessibilityLabel("Обновить лимиты")
                    .keyboardShortcut("r", modifiers: .command)
                Button { addingService = true } label: { Image(systemName: "plus") }
                    .help("Добавить сервис").accessibilityLabel("Добавить сервис")
                SettingsLink { Image(systemName: "gearshape") }
                    .help("Подключения и настройки").accessibilityLabel("Подключения и настройки")
                Button { model.shutdown(); NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .help("Завершить AI Limits").accessibilityLabel("Завершить AI Limits")
            }
            .buttonStyle(.borderless).font(.system(size: 11)).foregroundStyle(.secondary)
            .frame(height: 20)

            if let message = model.storageError {
                Text(message).font(.caption2).foregroundStyle(.orange)
            }
            ScrollView {
                VStack(spacing: 4) {
                    if cards.isEmpty && model.customServices.entries.isEmpty {
                        Text("Нет подключённых сервисов").font(.caption).foregroundStyle(.secondary)
                        SettingsLink { Text("Подключить сервисы") }.font(.caption)
                    } else {
                        ForEach(cards) { card in compactCard(card) }
                        ForEach(model.customServices.entries) { entry in CustomCompactCard(entry: entry) }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .frame(height: min(contentHeight, 440))
        }
        .padding(8)
        .frame(width: 280)
        .fixedSize(horizontal: false, vertical: true)
        .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        .sheet(isPresented: $addingService) { CustomServiceEditor(store: model.customServices) }
        .task(id: model.isRestored) {
            if model.isRestored { await model.panelOpened() }
        }
    }

    private func compactCard(_ card: AppModel.CardState) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                ServiceLogo(provider: card.provider)
                Text(card.provider.displayName).font(.system(size: 12, weight: .semibold))
                Spacer()
                if card.isRefreshing {
                    ProgressView().controlSize(.mini)
                } else if !card.isConnected {
                    SettingsLink { Text("Подключить") }.font(.system(size: 10))
                } else if let snapshot = card.snapshot {
                    let fresh = SnapshotPolicy.isFresh(fetchedAt: snapshot.fetchedAt,
                        observedAt: snapshot.observedAt, lastRefreshFailed: card.lastError != nil,
                        resetAt: snapshot.quotas.compactMap(\.resetsAt).min(), now: .now)
                    if !fresh {
                        Image(systemName: "clock.badge.exclamationmark")
                            .foregroundStyle(.orange).help("Данные устарели")
                            .accessibilityLabel("Данные устарели")
                    }
                    SettingsLink { Image(systemName: "ellipsis") }
                        .help("Подробности и подключение").accessibilityLabel("Подробности \(card.provider.displayName)")
                }
            }.frame(height: 18).buttonStyle(.borderless).font(.system(size: 10))

            if let balance = card.snapshot?.balanceUSD {
                HStack {
                    Text("Баланс").foregroundStyle(.secondary)
                    Spacer()
                    Text(ValueFormatting.usd(balance, threshold: 3)).fontWeight(.semibold)
                        .foregroundStyle(balance < 3 ? Color.orange : .primary)
                }.font(.system(size: 12)).frame(height: 20)
            }
            ForEach(quotas(card)) { quota in
                quotaRow(quota, provider: card.provider)
            }
            if (card.snapshot?.quotas.count ?? 0) > quotas(card).count {
                Button("Ещё лимиты · \((card.snapshot?.quotas.count ?? 0) - quotas(card).count)") {
                    expanded.insert(card.provider)
                }.buttonStyle(.borderless).font(.system(size: 10)).frame(height: 16)
            } else if expanded.contains(card.provider) {
                Button("Свернуть") { expanded.remove(card.provider) }
                    .buttonStyle(.borderless).font(.system(size: 10)).frame(height: 16)
            }
            if card.isConnected && card.snapshot == nil {
                Text(card.lastError == nil ? "Получаем лимиты…" : "Не удалось получить лимиты. Подробнее в настройках.")
                    .font(.system(size: 10)).foregroundStyle(card.lastError == nil ? Color.secondary : .orange)
                    .frame(height: 28, alignment: .leading)
            } else if card.lastError != nil {
                Text("Не удалось обновить · показаны прошлые данные")
                    .font(.system(size: 10)).foregroundStyle(.orange).frame(height: 28)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 6))
        .contextMenu {
            if expanded.contains(card.provider) {
                Button("Свернуть дополнительные лимиты") { expanded.remove(card.provider) }
            }
            Link("Кабинет", destination: CabinetLinks.url(for: card.provider))
        }
        .help(card.snapshot.map { "Обновлено \(ValueFormatting.ageLabel(since: $0.fetchedAt, now: .now))" } ?? card.provider.displayName)
    }

    private func quotaRow(_ quota: UsageQuota, provider: ProviderID) -> some View {
        VStack(spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(shortTitle(quota, provider: provider))
                    .foregroundStyle(.secondary).lineLimit(1).help(quota.title)
                if let reset = quota.resetsAt {
                    Text(reset <= Date() ? "проверяем сброс" : reset.formatted(.dateTime.day().month(.twoDigits).hour().minute()))
                        .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(quota.value.percent.map { "\(NSDecimalNumber(decimal: $0).intValue)%" }
                     ?? (quota.value == .unlimited ? "Без лимита" : "Нет данных"))
                    .fontWeight(.semibold).monospacedDigit().fixedSize()
            }.font(.system(size: 11))
            if let percent = quota.value.percent {
                GeometryReader { proxy in
                    Capsule().fill(.primary.opacity(0.10))
                        .overlay(alignment: .leading) {
                            Capsule().fill(percent <= 5 ? Color.red : percent <= 20 ? Color.orange : Color.accentColor)
                                .frame(width: proxy.size.width * NSDecimalNumber(decimal: percent).doubleValue / 100)
                        }
                }.frame(height: 3)
                    .accessibilityLabel("\(quota.title): осталось \(NSDecimalNumber(decimal: percent).intValue) процентов")
            }
        }.frame(height: 26)
    }

    private func shortTitle(_ quota: UsageQuota, provider: ProviderID) -> String {
        let period = ValueFormatting.windowLabel(windowSeconds: quota.windowSeconds)
        if provider == .codex && (quota.scope == "codex" || quota.id.hasPrefix("codex.codex.")) {
            return period ?? "Codex"
        }
        if let period, provider != .codex {
            return quota.title == "Окно" ? period : "\(quota.title) · \(period)"
        }
        return quota.title
    }
}
