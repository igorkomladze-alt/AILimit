import XCTest
import Foundation

/// Диагностический тест среды: pipes + readabilityHandler под xctest (несколько строк).
final class EnvDiagTests: XCTestCase {
    func testPipeReadabilityUnderXCTest() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("env-diag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("srv.sh")
        try "#!/bin/bash\nwhile IFS= read -r line; do\n  echo 'LINE1'\n  echo 'LINE2'\ndone\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let process = Process()
        process.executableURL = script
        process.currentDirectoryURL = dir
        process.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"]
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        final class Box: @unchecked Sendable { var out = Data(); var err = Data() }
        let box = Box()
        outPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { box.out.append(d) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { box.err.append(d) }
        }
        try process.run()
        try inPipe.fileHandleForWriting.write(contentsOf: Data("hello\n".utf8))
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, box.out.count < 14 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        process.terminate()
        XCTAssertEqual(String(data: box.out, encoding: .utf8), "LINE1\nLINE2\n",
                       "stderr: \(String(data: box.err, encoding: .utf8) ?? "?")")
    }
}
