import XCTest
import Foundation
import AILimitsCore
@testable import AILimitsMac

/// Task 12, шаг 1/2: изоляция helper, политика методов, поиск CLI, pipes-транспорт.
final class CodexProcessTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-limits-codex-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    /// Общий home отклоняется (план Task 12, шаг 1).
    func testSharedCodexHomeIsRejected() throws {
        let userHome = tempRoot.appendingPathComponent("foreign-codex", isDirectory: true)
        let config = CodexLaunchConfiguration(
            executable: URL(fileURLWithPath: "/bin/cat"),
            home: userHome, workingDirectory: userHome)
        XCTAssertThrowsError(try config.validate(userCodexHome: userHome))
    }

    /// Symlink-эквивалентный home отклоняется.
    func testSymlinkEquivalentHomeIsRejected() throws {
        let real = tempRoot.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = tempRoot.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let config = CodexLaunchConfiguration(
            executable: URL(fileURLWithPath: "/bin/cat"), home: link, workingDirectory: link)
        XCTAssertThrowsError(try config.validate(userCodexHome: real))
    }

    /// Изолированный home принимается.
    func testIsolatedHomeAccepted() throws {
        let own = tempRoot.appendingPathComponent("own", isDirectory: true)
        let foreign = tempRoot.appendingPathComponent("foreign", isDirectory: true)
        let config = CodexLaunchConfiguration(
            executable: URL(fileURLWithPath: "/bin/cat"), home: own, workingDirectory: own)
        XCTAssertNoThrow(try config.validate(userCodexHome: foreign))
    }

    /// Вложенность одного home в другой отклоняется.
    func testNestedHomeRejected() throws {
        let foreign = tempRoot.appendingPathComponent("foreign", isDirectory: true)
        let own = foreign.appendingPathComponent("nested", isDirectory: true)
        let config = CodexLaunchConfiguration(
            executable: URL(fileURLWithPath: "/bin/cat"), home: own, workingDirectory: own)
        XCTAssertThrowsError(try config.validate(userCodexHome: foreign))
    }

    /// Poll и login методы разделены и не пересекаются.
    func testPollAndLoginMethodsAreSeparate() {
        XCTAssertTrue(CodexProcessPolicy.pollMethods.isDisjoint(with: CodexProcessPolicy.loginMethods))
        XCTAssertTrue(CodexProcessPolicy.pollMethods.contains("account/rateLimits/read"))
        XCTAssertTrue(CodexProcessPolicy.loginMethods.contains("account/login/start"))
        // Генераций и инструментов нет ни в одном списке.
        XCTAssertFalse(CodexProcessPolicy.pollMethods.contains("thread/start"))
        XCTAssertFalse(CodexProcessPolicy.loginMethods.contains("turn/start"))
    }

    /// Локатор: несуществующие пути не принимаются; отсутствие CLI → dependencyMissing.
    func testLocatorRejectsMissing() {
        let locator = CodexExecutableLocator(candidates: [
            tempRoot.appendingPathComponent("nope-1"),
            tempRoot.appendingPathComponent("nope-2")
        ])
        XCTAssertThrowsError(try locator.locate()) { error in
            XCTAssertEqual(error as? ProviderError, .dependencyMissing)
        }
    }

    /// Локатор принимает реальный исполняемый файл.
    func testLocatorFindsExecutable() throws {
        let locator = CodexExecutableLocator(candidates: [
            tempRoot.appendingPathComponent("nope"),
            URL(fileURLWithPath: "/bin/cat")
        ])
        XCTAssertEqual(try locator.locate(), URL(fileURLWithPath: "/bin/cat"))
    }

    /// Исполняемый symlink на regular-файл допустим (homebrew-стиль).
    func testLocatorAcceptsSymlinkToExecutable() throws {
        let link = tempRoot.appendingPathComponent("codex")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: URL(fileURLWithPath: "/bin/cat"))
        let locator = CodexExecutableLocator(candidates: [link])
        XCTAssertEqual(try locator.locate(), link)
    }

    /// Pipes-транспорт: echo-сервер (/bin/cat) возвращает линию без result —
    /// ответ с нужным id не приходит, срабатывает timeout (детерминированно).
    func testTransportTimeoutOnMissingResult() async throws {
        let home = tempRoot.appendingPathComponent("own", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let config = CodexLaunchConfiguration(
            executable: URL(fileURLWithPath: "/bin/cat"), home: home, workingDirectory: home)
        try config.validate(userCodexHome: tempRoot.appendingPathComponent("foreign", isDirectory: true))
        let transport = CodexProcessTransport(configuration: config, arguments: [])
        try await transport.start()
        do {
            _ = try await transport.request(
                line: #"{"method":"account/read","id":42,"params":{}}"#, timeout: 1)
            XCTFail("echo без result должен завершиться timeout")
        } catch {
            XCTAssertEqual(error as? ProviderError, .timeout)
        }
        await transport.stop()
        let running = await transport.isRunning
        XCTAssertFalse(running)
    }

    /// Запрос с notification до ответа: notification пропускается, ответ с нужным id находится.
    func testTransportSkipsNotifications() async throws {
        let home = tempRoot.appendingPathComponent("own2", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        // Фейковый сервер: отвечает notification, затем result с нужным id.
        // Только одиночные кавычки — двойные в Swift multiline ломают bash-синтаксис.
        let script = tempRoot.appendingPathComponent("fake-server.sh")
        try """
        #!/bin/bash
        while IFS= read -r line; do
          echo '{"method":"account/login/completed","params":{}}'
          echo '{"id":7,"result":{"ok":true}}'
        done
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let config = CodexLaunchConfiguration(
            executable: script, home: home, workingDirectory: home)
        let transport = CodexProcessTransport(configuration: config, arguments: [])
        try await transport.start()
        do {
            let result = try await transport.request(
                line: #"{"method":"account/rateLimits/read","id":7}"#, timeout: 5)
            let object = try JSONSerialization.jsonObject(with: result) as? [String: Any]
            XCTAssertEqual(object?["ok"] as? Bool, true)
            let notification = try await transport.waitNotification(method: "account/login/completed", timeout: 0.2)
            XCTAssertFalse(notification.isEmpty)
        } catch {
            let stderr = await transport.stderrSummary()
            let bytes = await transport.stdoutByteCount()
            let running = await transport.isRunning
            XCTFail("request failed: \(error); stderr: \(stderr); stdoutBytes: \(bytes); running: \(running)")
        }
        await transport.stop()
    }
}
