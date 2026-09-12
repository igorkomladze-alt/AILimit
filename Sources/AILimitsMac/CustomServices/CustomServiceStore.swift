import Foundation
import Combine
import AILimitsCore

/// Public configuration and normalized measurements only; credentials never enter this file.
public struct CustomServiceEntry: Codable, Sendable, Identifiable {
    public var id: UUID { definition.id }
    public var definition: CustomServiceDefinition
    public var snapshot: CustomServiceSnapshot?
    public var isRefreshing: Bool = false
    public var error: String?
    fileprivate var generation: UUID
    fileprivate var nextAttempt: Date?
    fileprivate var failures: Int = 0
    enum CodingKeys: String, CodingKey { case definition, snapshot, generation, nextAttempt, failures }
}
private struct CustomServicesEnvelope: Codable, Sendable {
    var version = 1
    var entries: [CustomServiceEntry]
}

/// No timer: the application owns refresh cadence. Custom services have no notification rules.
@MainActor public final class CustomServiceStore: ObservableObject {
    @Published public private(set) var entries: [CustomServiceEntry] = []
    private let file: AtomicJSONFile<CustomServicesEnvelope>
    private let transport: any HTTPTransport
    private let vault: any SecretVault
    private let readSecret: @Sendable (String) throws -> Data
    private var refreshing = false
    private var networkBusy = false
    private var saving: Set<UUID> = []
    private var revisions: [UUID: UUID] = [:]

    public init(directory: URL? = nil, transport: any HTTPTransport = URLSessionTransport(), vault: any SecretVault = KeychainVault(), readSecret: @escaping @Sendable (String) throws -> Data = { try KeychainVault().read(account: $0, interaction: .background) }) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AILimits", isDirectory: true)
        self.file = AtomicJSONFile(directory: base, fileName: "custom-services.json", expectedVersion: 1, version: { $0.version })
        self.transport = transport; self.vault = vault; self.readSecret = readSecret
        if let saved = file.read(), saved.entries.count <= 20, Set(saved.entries.map(\.id)).count == saved.entries.count, saved.entries.allSatisfy({ (try? $0.definition.validate()) != nil }) { entries = saved.entries }
    }
    private func account(id: UUID, generation: UUID) -> String { "custom:\(id.uuidString):\(generation.uuidString)" }
    private func persist(_ candidate: [CustomServiceEntry]) throws { try file.write(CustomServicesEnvelope(entries: candidate)) }
    private func key(for definition: CustomServiceDefinition, supplied: String) throws -> String {
        if definition.auth == .none { return "" }
        if !supplied.isEmpty { return supplied }
        guard let old = entries.first(where: { $0.id == definition.id }), old.definition.auth != .none else { throw CustomServiceError.invalid("Введите API-ключ.") }
        // A blank edit may preserve a credential only for the original origin.
        guard old.definition.endpoint.host == definition.endpoint.host, old.definition.endpoint.port == definition.endpoint.port else { throw CustomServiceError.invalid("Для нового адреса введите ключ заново.") }
        guard let secret = String(data: try readSecret(account(id: old.id, generation: old.generation)), encoding: .utf8), !secret.isEmpty else { throw CustomServiceError.invalid("Ключ недоступен. Введите его заново.") }
        return secret
    }
    public func preview(definition: CustomServiceDefinition, key: String) async throws -> CustomServiceSnapshot {
        do { try definition.validate(); return try await fetch(definition, key: self.key(for: definition, supplied: key)) }
        catch is CancellationError { throw CancellationError() }
        catch let error as CustomServiceError { throw error }
        catch { throw CustomServiceError.invalid("Не удалось прочитать сервис. Проверьте доступ и ключ.") }
    }
    private func fetch(_ definition: CustomServiceDefinition, key: String) async throws -> CustomServiceSnapshot {
        try definition.validate()
        guard !networkBusy else { throw CustomServiceError.invalid("Дождитесь завершения текущего запроса.") }
        networkBusy = true; defer { networkBusy = false }
        guard !key.contains("\r"), !key.contains("\n"), key.count <= 8192 else { throw CustomServiceError.invalid("Некорректный API-ключ.") }
        var request = URLRequest(url: definition.endpoint); request.httpMethod = "GET"; request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        switch definition.auth {
        case .none: break
        case .bearer: request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .apiKey: request.setValue(key, forHTTPHeaderField: "X-API-Key")
        }
        let response = try await transport.send(request)
        try Task.checkCancellation()
        guard (200...299).contains(response.status) else {
            if response.status == 429 { throw CustomFetchFailure.rateLimited(HTTPStatusPolicy.retryAfter(headers: response.headers, now: Date()) ?? Date().addingTimeInterval(60)) }
            throw CustomServiceError.invalid("Сервис вернул HTTP \(response.status). Проверьте адрес и доступ.")
        }
        return try CustomJSONParser.parse(response.body, definition: definition)
    }
    public func save(definition: CustomServiceDefinition, key: String) async throws {
        guard !saving.contains(definition.id) else { throw CustomServiceError.invalid("Сохранение уже выполняется.") }
        guard entries.contains(where: { $0.id == definition.id }) || entries.count < 20 else { throw CustomServiceError.invalid("Можно добавить не более 20 сервисов.") }
        saving.insert(definition.id); defer { saving.remove(definition.id) }
        let revision = UUID(); revisions[definition.id] = revision
        do {
            try definition.validate()
            let resolved = try self.key(for: definition, supplied: key)
            let snapshot = try await fetch(definition, key: resolved)
            try Task.checkCancellation()
            guard revisions[definition.id] == revision else { throw CancellationError() }
            guard entries.contains(where: { $0.id == definition.id }) || entries.count < 20 else { throw CustomServiceError.invalid("Можно добавить не более 20 сервисов.") }
            let old = entries.first(where: { $0.id == definition.id })
            let generation = UUID()
            let entry = CustomServiceEntry(definition: definition, snapshot: snapshot, generation: generation)
            if definition.auth != .none { try vault.save(secret: Data(resolved.utf8), account: account(id: definition.id, generation: generation)) }
            var candidate = entries.filter { $0.id != definition.id }; candidate.append(entry)
            do { try persist(candidate) }
            catch { if definition.auth != .none { try? vault.delete(account: account(id: definition.id, generation: generation)) }; throw error }
            entries = candidate
            if let old, old.definition.auth != .none { try? vault.delete(account: account(id: old.id, generation: old.generation)) }
        } catch is CancellationError { throw CancellationError() }
        catch let error as CustomServiceError { throw error }
        catch { throw CustomServiceError.invalid("Не удалось сохранить сервис. Проверьте подключение и доступ к Связке ключей.") }
    }
    public func delete(id: UUID) throws {
        revisions[id] = UUID()
        guard let old = entries.first(where: { $0.id == id }) else { return }
        let candidate = entries.filter { $0.id != id }
        do { try persist(candidate); entries = candidate; if old.definition.auth != .none { try vault.delete(account: account(id: id, generation: old.generation)) } }
        catch { throw CustomServiceError.invalid("Не удалось полностью удалить сервис или его ключ.") }
    }
    public func refreshAll(force: Bool = false) async {
        guard !refreshing, !networkBusy else { return }
        refreshing = true; defer { refreshing = false }
        for id in entries.map(\.id) {
            if Task.isCancelled { return }
            guard let index = entries.firstIndex(where: { $0.id == id }), !saving.contains(id) else { continue }
            let entry = entries[index]
            // Retry-After is honored even when manually refreshing.
            if let next = entry.nextAttempt, next > Date() { continue }
            if !force, let snapshot = entry.snapshot, Date().timeIntervalSince(snapshot.observedAt) < RefreshPolicy.backoffSeconds(failures: 0) { continue }
            let revision = UUID(); revisions[id] = revision; entries[index].isRefreshing = true
            defer { if let current = entries.firstIndex(where: { $0.id == id }) { entries[current].isRefreshing = false } }
            do {
                let snapshot = try await fetch(entry.definition, key: key(for: entry.definition, supplied: ""))
                guard revisions[id] == revision, let current = entries.firstIndex(where: { $0.id == id }) else { continue }
                entries[current].snapshot = snapshot; entries[current].error = nil; entries[current].failures = 0; entries[current].nextAttempt = nil
            } catch {
                if Task.isCancelled { return }
                guard revisions[id] == revision, let current = entries.firstIndex(where: { $0.id == id }) else { continue }
                entries[current].failures += 1
                if case CustomFetchFailure.rateLimited(let date) = error {
                    entries[current].nextAttempt = RefreshPolicy.earliestRetry(failureAt: Date(), failures: entries[current].failures, retryAfter: date); entries[current].error = "Сервис ограничил частоту запросов. Повторим позже."
                } else {
                    entries[current].nextAttempt = RefreshPolicy.earliestRetry(failureAt: Date(), failures: entries[current].failures, retryAfter: nil)
                    entries[current].error = (error as? CustomServiceError)?.errorDescription ?? "Не удалось обновить сервис. Проверьте подключение и ключ."
                }
            }
            do { try persist(entries) } catch { if let current = entries.firstIndex(where: { $0.id == id }) { entries[current].error = "Не удалось сохранить результат обновления." } }
        }
    }
}
private enum CustomFetchFailure: Error { case rateLimited(Date) }
