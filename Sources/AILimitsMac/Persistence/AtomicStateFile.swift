import Foundation
import Darwin
import AILimitsCore

/// Атомарное JSON-хранилище значения.
/// Каталог 0700, файл 0600; запись через временный файл + rename.
/// Чтение отклоняет symlink при проверке типа файла.
public struct AtomicJSONFile<Value: Codable & Sendable>: Sendable {
    public let directory: URL
    public let fileName: String
    /// nil — без проверки версии схемы.
    private let expectedVersion: Int?
    private let version: @Sendable (Value) -> Int

    public init(directory: URL, fileName: String, expectedVersion: Int? = nil, version: @escaping @Sendable (Value) -> Int = { _ in 0 }) {
        self.directory = directory
        self.fileName = fileName
        self.expectedVersion = expectedVersion
        self.version = version
    }

    public var fileURL: URL { directory.appendingPathComponent(fileName) }

    /// Проверить, что путь — обычный файл (не symlink, не каталог).
    private func isRegularFile(_ path: String) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let type = attributes[.type] as? FileAttributeType else { return false }
        return type == FileAttributeType.typeRegular
    }

    /// Прочитать значение. Повреждённый JSON / неизвестная версия → nil
    /// (безопасный старт без значений; секреты в Keychain не затрагиваются).
    public func read() -> Value? {
        let path = fileURL.path
        guard isRegularFile(path) else { return nil }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        guard let value = try? decoder.decode(Value.self, from: data) else { return nil }
        if let expectedVersion, version(value) != expectedVersion { return nil }
        return value
    }

    /// Атомарная запись: приватный каталог, уникальный tmp, права 0600, rename.
    public func write(_ value: Value) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let data = try JSONEncoder().encode(value)

        // Уникальный временный файл исключает коллизии конкурирующих писателей.
        // withoutOverwriting не следует заранее подставленной ссылке.
        let temporary = directory.appendingPathComponent(".\(fileName).\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        // POSIX rename заменяет directory entry атомарно, включая symlink.
        // При отказе прежний destination остается нетронутым.
        guard Darwin.rename(temporary.path, fileURL.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

/// Task 5, шаг 4: атомарное хранилище state.json (AppEnvelope v1).
public typealias AtomicStateFile = AtomicJSONFile<AppEnvelope>

public extension AtomicJSONFile where Value == AppEnvelope {
    init(directory: URL? = nil, fileName: String = "state.json") {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AILimits", isDirectory: true)
        self.init(directory: base, fileName: fileName,
                  expectedVersion: AppEnvelope.currentVersion, version: { $0.version })
    }
}
