import XCTest
import AILimitsCore
@testable import AILimitsMac

/// Task 5, шаг 5: AtomicStateFile — права, отказ symlink, сохранность при отказе.
final class AtomicStateFileTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ailimits-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeEnvelope(balance: Decimal = 5) -> AppEnvelope {
        let connection = ConnectionRecord(
            id: ConnectionID(provider: .openrouter, generation: UUID()),
            source: .manualKey,
            verifiedIdentityHash: nil
        )
        var envelope = AppEnvelope()
        envelope.connections["openrouter"] = .init(record: connection)
        let snapshot = UsageSnapshot(
            connection: connection.id,
            source: "openrouter.credits.v1",
            fetchedAt: Date(timeIntervalSince1970: 1_800_000_000),
            quotas: [],
            balanceUSD: balance
        )
        envelope.snapshots["openrouter"] = .init(snapshot: snapshot)
        return envelope
    }

    func testWriteReadRoundTripKeepsFetchedAtAndDecimal() throws {
        let file = AtomicStateFile(directory: tempDir)
        let envelope = makeEnvelope(balance: Decimal(string: "2.9999")!)
        try file.write(envelope)

        let restored = try XCTUnwrap(file.read())
        XCTAssertEqual(restored.snapshots["openrouter"]?.snapshot.balanceUSD, Decimal(string: "2.9999"))
        XCTAssertEqual(restored.snapshots["openrouter"]?.snapshot.fetchedAt,
                       Date(timeIntervalSince1970: 1_800_000_000))
    }

    func testFailedReplacementPreservesExistingDestination() throws {
        let file = AtomicStateFile(directory: tempDir)
        try FileManager.default.createDirectory(at: file.fileURL, withIntermediateDirectories: true)
        let marker = file.fileURL.appendingPathComponent("keep")
        try Data("keep".utf8).write(to: marker)
        XCTAssertThrowsError(try file.write(makeEnvelope()))
        XCTAssertEqual(try Data(contentsOf: marker), Data("keep".utf8))
    }

    func testPermissions0700And0600() throws {
        let file = AtomicStateFile(directory: tempDir)
        try file.write(makeEnvelope())

        let dirAttrs = try FileManager.default.attributesOfItem(atPath: tempDir.path)
        XCTAssertEqual(dirAttrs[.posixPermissions] as? NSNumber, 0o700)
        let fileAttrs = try FileManager.default.attributesOfItem(atPath: file.fileURL.path)
        XCTAssertEqual(fileAttrs[.posixPermissions] as? NSNumber, 0o600)
    }

    /// В файле нет токенов: ни "key", ни "secret", ни "Bearer" (план Task 5, шаг 5).
    func testNoCredentialPayloadInFile() throws {
        let file = AtomicStateFile(directory: tempDir)
        try file.write(makeEnvelope())
        let raw = try String(contentsOf: file.fileURL, encoding: .utf8)
        XCTAssertFalse(raw.lowercased().contains("bearer"))
        XCTAssertFalse(raw.lowercased().contains("apikey"))
        XCTAssertFalse(raw.lowercased().contains("sk-"))
    }

    /// Файл-симлинк по пути state.json: чтение возвращает nil, не следует по ссылке.
    func testSymlinkAtStatePathRejected() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let secretTarget = tempDir.appendingPathComponent("victim.txt")
        try Data("victim".utf8).write(to: secretTarget)
        try FileManager.default.createSymbolicLink(
            at: AtomicStateFile(directory: tempDir).fileURL,
            withDestinationURL: secretTarget)

        let file = AtomicStateFile(directory: tempDir)
        XCTAssertNil(file.read(), "чтение не должно следовать symlink")
        // Victim-файл не тронут.
        XCTAssertEqual(try String(contentsOf: secretTarget, encoding: .utf8), "victim")
    }

    /// Повреждённый JSON → nil, безопасный старт.
    func testCorruptedJSONYieldsNil() throws {
        let file = AtomicStateFile(directory: tempDir)
        try file.write(makeEnvelope())
        try Data("{{{corrupted".utf8).write(to: file.fileURL)
        XCTAssertNil(file.read())
    }

    /// Неизвестная версия схемы → nil.
    func testUnknownVersionYieldsNil() throws {
        let file = AtomicStateFile(directory: tempDir)
        let unknown = AppEnvelope(version: 999)
        try file.write(unknown)
        XCTAssertNil(file.read())
    }
}
