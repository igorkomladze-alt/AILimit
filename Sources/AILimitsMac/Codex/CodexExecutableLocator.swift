import Foundation
import AILimitsCore

/// Task 12, шаг 4: поиск официального Codex CLI.
/// Только известные пути или явный выбор пользователя; скрытого npm/brew install нет.
/// Имя файла само по себе ничего не доказывает: требуется исполняемый regular/symlink→regular
/// файл. Отсутствие подходящего CLI → dependencyMissing.
public struct CodexExecutableLocator: Sendable {
    /// Кандидаты в порядке приоритета (инъекция для тестов).
    public let candidates: [URL]

    public init(candidates: [URL]? = nil) {
        if let candidates {
            self.candidates = candidates
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            self.candidates = [
                URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
                URL(fileURLWithPath: "/usr/local/bin/codex"),
                home.appendingPathComponent(".local/bin/codex")
            ]
        }
    }

    /// Найти поддерживаемый CLI или .dependencyMissing.
    public func locate() throws -> URL {
        for candidate in candidates {
            if Self.isUsableExecutable(candidate) { return candidate }
        }
        throw ProviderError.dependencyMissing
    }

    /// Исполняемый файл: существует, исполняем, после разрешения symlink — обычный файл.
    static func isUsableExecutable(_ url: URL) -> Bool {
        let path = url.path
        guard FileManager.default.isExecutableFile(atPath: path) else { return false }
        let resolved = url.resolvingSymlinksInPath().path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolved),
              let type = attributes[.type] as? FileAttributeType else { return false }
        return type == .typeRegular
    }
}
