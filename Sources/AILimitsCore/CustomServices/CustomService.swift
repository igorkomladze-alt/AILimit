import Foundation

public enum CustomServiceAuth: String, Codable, Sendable, CaseIterable { case none, bearer, apiKey }
public enum CustomMetricKind: String, Codable, Sendable, CaseIterable { case remainingPercent, usedPercent, balance, remainingCounts, usedCounts }
public struct CustomMetric: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID; public var name: String; public var valuePath: String; public var kind: CustomMetricKind
    public var totalPath: String?; public var resetPath: String?; public var windowSeconds: TimeInterval?; public var currency: String?; public var currencyPath: String?
    public init(id: UUID = UUID(), name: String, valuePath: String, kind: CustomMetricKind, totalPath: String? = nil, resetPath: String? = nil, windowSeconds: TimeInterval? = nil, currency: String? = nil, currencyPath: String? = nil) {
        self.id = id; self.name = name; self.valuePath = valuePath; self.kind = kind; self.totalPath = totalPath; self.resetPath = resetPath; self.windowSeconds = windowSeconds; self.currency = currency; self.currencyPath = currencyPath
    }
}
public struct CustomServiceDefinition: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID; public var name: String; public var endpoint: URL; public var auth: CustomServiceAuth; public var metrics: [CustomMetric]
    public init(id: UUID = UUID(), name: String, endpoint: URL, auth: CustomServiceAuth = .none, metrics: [CustomMetric]) { self.id = id; self.name = name; self.endpoint = endpoint; self.auth = auth; self.metrics = metrics }
    public func validate() throws {
        guard endpoint.scheme?.lowercased() == "https", endpoint.host?.isEmpty == false, endpoint.user == nil, endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil else { throw CustomServiceError.invalid("Нужен HTTPS-адрес без логина, параметров и фрагмента.") }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 80, (1...8).contains(metrics.count), Set(metrics.map(\.id)).count == metrics.count else { throw CustomServiceError.invalid("Укажите название и от 1 до 8 показателей.") }
        for metric in metrics {
            guard !metric.name.isEmpty, metric.name.count <= 80 else { throw CustomServiceError.invalid("Укажите название показателя до 80 символов.") }
            if [.remainingCounts, .usedCounts].contains(metric.kind), metric.totalPath == nil { throw CustomServiceError.invalid("Для количества укажите путь общего лимита.") }
            let countKind = [.remainingCounts, .usedCounts].contains(metric.kind)
            for path in [metric.valuePath, countKind ? metric.totalPath : nil, metric.resetPath, metric.kind == .balance ? metric.currencyPath : nil].compactMap({ $0 }) {
                guard !path.isEmpty, path.count <= 256, path.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty }) else { throw CustomServiceError.invalid("Некорректный путь JSON.") }
            }
            if metric.kind == .balance, let currency = metric.currency, currency.range(of: "^[A-Z]{3}$", options: .regularExpression) == nil { throw CustomServiceError.invalid("Валюта должна быть трёхбуквенным кодом, например USD.") }
            if let duration = metric.windowSeconds, !duration.isFinite || duration <= 0 { throw CustomServiceError.invalid("Длительность окна должна быть положительной.") }
        }
    }
}
public enum CustomServiceError: Error, LocalizedError, Sendable {
    case invalid(String)
    public var errorDescription: String? { switch self { case .invalid(let message): return message } }
}
public struct CustomMetricValue: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID { metric.id }
    public let metric: CustomMetric; public let value: Decimal; public let total: Decimal?; public let resetAt: Date?; public let currency: String?
}
public struct CustomServiceSnapshot: Codable, Sendable, Equatable {
    public let metrics: [CustomMetricValue]; public let observedAt: Date
}
public enum CustomJSONParser {
    public static func parse(_ data: Data, definition: CustomServiceDefinition, now: Date = Date()) throws -> CustomServiceSnapshot {
        try definition.validate()
        guard data.count <= 2 * 1024 * 1024, let root = try? JSONDecoder().decode(CustomJSONNode.self, from: data) else { throw CustomServiceError.invalid("Сервис вернул некорректный JSON.") }
        func resolve(_ path: String) throws -> CustomJSONNode {
            var current = root
            for part in path.split(separator: ".") {
                if case .object(let object) = current, let next = object[String(part)] { current = next }
                else if case .array(let array) = current, let index = Int(part), array.indices.contains(index) { current = array[index] }
                else { throw CustomServiceError.invalid("Путь JSON не найден: \(path)") }
            }
            return current
        }
        func number(_ path: String) throws -> Decimal {
            let raw = try resolve(path)
            let text: String
            if case .number(let value) = raw { return value }
            else if case .string(let value) = raw { text = value.trimmingCharacters(in: .whitespacesAndNewlines) }
            else { throw CustomServiceError.invalid("По пути \(path) ожидается число.") }
            guard text.range(of: #"^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil, let result = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), !result.isNaN else { throw CustomServiceError.invalid("По пути \(path) ожидается конечное число.") }
            return result
        }
        let values = try definition.metrics.map { metric in
            let value = try number(metric.valuePath)
            guard (metric.kind == .balance || value >= 0), ![.usedPercent, .remainingPercent].contains(metric.kind) || value <= 100 else { throw CustomServiceError.invalid("Значение показателя вне допустимого диапазона.") }
            let total = try [.remainingCounts, .usedCounts].contains(metric.kind) ? metric.totalPath.map(number) : nil
            if let total, total <= 0 { throw CustomServiceError.invalid("Общий лимит должен быть больше нуля.") }
            if let total, [.remainingCounts, .usedCounts].contains(metric.kind), value > total { throw CustomServiceError.invalid("Значение показателя превышает общий лимит.") }
            var reset: Date?
            if let path = metric.resetPath {
                let raw = try resolve(path)
                if case .string(let text) = raw {
                    let formatter = ISO8601DateFormatter()
                    reset = formatter.date(from: text)
                    if reset == nil { formatter.formatOptions.insert(.withFractionalSeconds); reset = formatter.date(from: text) }
                }
                if reset == nil, let epoch = try? number(path) { let seconds = NSDecimalNumber(decimal: epoch).doubleValue; if seconds.isFinite { reset = Date(timeIntervalSince1970: seconds) } }
                guard reset != nil else { throw CustomServiceError.invalid("Дата сброса должна быть ISO 8601 или Unix-временем в секундах.") }
            }
            var currency = metric.kind == .balance ? (metric.currency ?? "USD") : nil
            if metric.kind == .balance, let path = metric.currencyPath {
                guard case .string(let code) = try resolve(path), code.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil else { throw CustomServiceError.invalid("По пути валюты ожидается трёхбуквенный код.") }
                currency = code
            }
            return CustomMetricValue(metric: metric, value: value, total: total, resetAt: reset, currency: currency)
        }
        return CustomServiceSnapshot(metrics: values, observedAt: now)
    }
}

private indirect enum CustomJSONNode: Decodable {
    case object([String: CustomJSONNode]), array([CustomJSONNode]), number(Decimal), string(String), other
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .other }
        else if (try? container.decode(Bool.self)) != nil { self = .other }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(Decimal.self) { self = .number(value) }
        else if let value = try? container.decode([String: CustomJSONNode].self) { self = .object(value) }
        else { self = .array(try container.decode([CustomJSONNode].self)) }
    }
}
