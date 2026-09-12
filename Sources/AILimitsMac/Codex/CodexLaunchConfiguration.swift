import Foundation
import AILimitsCore

/// Task 12, шаг 1/3: неизменяемая конфигурация запуска Codex helper.
/// Изоляция: собственный CODEX_HOME не совпадает (в т.ч. через symlink)
/// с пользовательским ~/.codex — чужой вход недоступен процессу.
public struct CodexLaunchConfiguration: Sendable, Equatable {
    public let executable: URL
    /// Изолированный CODEX_HOME (по умолчанию ~/Library/Application Support/AILimits/CodexHome).
    public let home: URL
    /// Нейтральный рабочий каталог (не проект пользователя).
    public let workingDirectory: URL

    public init(executable: URL, home: URL, workingDirectory: URL) {
        self.executable = executable
        self.home = home
        self.workingDirectory = workingDirectory
    }

    /// Канонический путь с разрешёнными symlink (homebrew-стиль ссылок допустим,
    /// но цель не должна совпадать с чужим home).
    private static func canonical(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Запрет общего или symlink-эквивалентного home (план Task 12, шаг 1).
    /// Также запрещено вложение одного home в другой.
    public func validate(userCodexHome: URL) throws {
        let own = Self.canonical(home)
        let foreign = Self.canonical(userCodexHome)
        guard own != foreign else { throw ProviderError.permissionDenied }
        guard !own.hasPrefix(foreign + "/"), !foreign.hasPrefix(own + "/") else {
            throw ProviderError.permissionDenied
        }
    }

    /// Изолированный home приложения по умолчанию.
    public static func defaultIsolatedHome() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AILimits/CodexHome", isDirectory: true)
    }

    /// Пользовательский CODEX_HOME по умолчанию (чужой, только для сравнения путей).
    public static func defaultUserHome() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
    }
}
