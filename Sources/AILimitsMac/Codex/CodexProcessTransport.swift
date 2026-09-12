import Foundation
import AILimitsCore

/// Task 12, шаг 4/5: процессный транспорт Codex app-server по pipes (JSONL).
/// - Только pipes: локальный сетевой listener не поднимается.
/// - Изолированный CODEX_HOME, минимальный PATH, без login shell и shell-конфигов.
/// - Токены не передаются в arguments/environment.
/// - Жизненный цикл: только собственный child PID; terminate с grace, без pkill.
/// - stderr ограничен (64 KiB tail) и не сохраняется на диск.
public actor CodexProcessTransport {
    /// Поток входящих JSONL-линий с поддержкой ошибки завершения.
    private final class LineBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [Data] = []
        private var terminalError: Error?

        func push(_ line: Data) {
            lock.lock()
            defer { lock.unlock() }
            guard terminalError == nil else { return }
            // Bound unsolicited output; never grow memory without a limit.
            guard lines.count < 4096 else {
                terminalError = ProviderError.invalidData
                return
            }
            lines.append(line)
        }

        func poll(matching predicate: (Data) -> Bool) throws -> Data? {
            lock.lock()
            defer { lock.unlock() }
            if let index = lines.firstIndex(where: predicate) { return lines.remove(at: index) }
            if let terminalError { throw terminalError }
            return nil
        }

        func fail(_ error: Error) {
            lock.lock()
            defer { lock.unlock() }
            terminalError = error
        }
    }

    public let configuration: CodexLaunchConfiguration
    /// Аргументы запуска (по умолчанию — app-server с keyring-хранилищем).
    private let arguments: [String]
    private var process: Process?
    private var stdinPipe: Pipe?
    private let buffer = LineBuffer()
    private let stdoutAssembler: StdoutAssembler
    /// stderr: ограниченный хвост, только в памяти (не на диск, не в журнал).
    private var stderrTail = Data()
    private let stderrLimit = 64 * 1024
    public private(set) var isRunning = false

    public init(configuration: CodexLaunchConfiguration, arguments: [String]? = nil) {
        self.configuration = configuration
        self.arguments = arguments ?? [
            "-c", "cli_auth_credentials_store=\"keyring\"", "app-server"
        ]
        self.stdoutAssembler = StdoutAssembler(buffer: buffer)
    }

    /// Склейка входящего потока в JSONL-линии (per-instance, потокобезопасно).
    private final class StdoutAssembler: @unchecked Sendable {
        private var pending = Data()
        private let lock = NSLock()
        private let buffer: LineBuffer
        /// Диагностика: сколько байт stdout получено от процесса.
        private(set) var receivedBytes = 0

        init(buffer: LineBuffer) { self.buffer = buffer }

        func ingest(_ chunk: Data) {
            lock.lock()
            receivedBytes += chunk.count
            pending.append(chunk)
            var lines: [Data] = []
            while let newline = pending.firstIndex(of: 0x0A) {
                lines.append(pending.subdata(in: pending.startIndex..<newline))
                pending.removeSubrange(pending.startIndex...newline)
            }
            lock.unlock()
            for line in lines where !line.isEmpty {
                buffer.push(line)
            }
        }
    }

    // MARK: - Жизненный цикл

    public func start() throws {
        guard process == nil else { return }
        let process = Process()
        process.executableURL = configuration.executable
        process.arguments = arguments
        process.currentDirectoryURL = configuration.workingDirectory
        // Изоляция: свой CODEX_HOME, нейтральный PATH, без прокси/auth overrides окружения.
        process.environment = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "CODEX_HOME": configuration.home.path,
            "PATH": "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        ]
        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        let assembler = self.stdoutAssembler
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            assembler.ingest(chunk)
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            Task { await self?.appendStderr(chunk) }
        }
        process.terminationHandler = { [weak self] _ in
            Task { await self?.markTerminated() }
        }

        try process.run()
        self.process = process
        self.stdinPipe = inPipe
        self.isRunning = true
    }

    private func appendStderr(_ chunk: Data) {
        stderrTail.append(chunk)
        if stderrTail.count > stderrLimit {
            stderrTail = stderrTail.suffix(stderrLimit)
        }
    }

    /// Диагностический хвост stderr (ограничен; не для журналов — только отладка/тесты).
    public func stderrSummary() -> String {
        String(data: stderrTail.suffix(2048), encoding: .utf8) ?? ""
    }

    /// Диагностика: сколько байт stdout получено от процесса.
    public func stdoutByteCount() -> Int {
        stdoutAssembler.receivedBytes
    }

    private func markTerminated() {
        isRunning = false
        process = nil
        stdinPipe = nil
        buffer.fail(ProviderError.disconnected)
    }

    // MARK: - Протокол

    /// Отправить JSONL-линию. Allowlist проверяется вызывающей стороной (CodexServerController).
    public func send(line: String) throws {
        guard isRunning, let stdinPipe else { throw ProviderError.disconnected }
        try stdinPipe.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
    }

    /// Запрос-ответ: ждёт линию с тем же id, пропуская notifications.
    /// Timeout по умолчанию — 30 секунд (спецификация §7).
    public func request(line: String, timeout: TimeInterval = 30) async throws -> Data {
        guard let id = CodexRPCCodec.requestID(line: line) else { throw ProviderError.invalidData }
        try send(line: line)
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            try Task.checkCancellation()
            if let data = try buffer.poll(matching: { data in
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
                return object["id"] as? Int == id && (object["result"] != nil || object["error"] != nil)
            }) {
                if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   object["error"] != nil { throw ProviderError.invalidData }
                if let result = CodexRPCCodec.extractResult(line: data, expectingID: id) {
                    return result
                }
                continue // notification или чужой id — ждём дальше
            }
            guard Date() < deadline else { throw ProviderError.timeout }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Дождаться notification с указанным методом (login/completed). Чужие линии пропускаются.
    public func waitNotification(method: String, timeout: TimeInterval) async throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            try Task.checkCancellation()
            if let data = try buffer.poll(matching: { CodexRPCCodec.notificationMethod(line: $0) == method }) {
                if CodexRPCCodec.notificationMethod(line: data) == method {
                    return data
                }
                continue
            }
            guard Date() < deadline else { throw ProviderError.timeout }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    // MARK: - Остановка

    /// Закрыть pipes, terminate собственного child с конечным grace; без pkill.
    public func stop() {
        guard let process else { return }
        if let stdinPipe {
            try? stdinPipe.fileHandleForWriting.close()
        }
        stdinPipe = nil
        if process.isRunning {
            process.terminate()
            // Grace до 3 секунд; затем завершить ТОЛЬКО этот child.
            let deadline = Date().addingTimeInterval(3)
            while process.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        self.process = nil
        isRunning = false
        buffer.fail(ProviderError.cancelled)
    }
}
