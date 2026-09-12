import XCTest
@testable import AILimitsCore

/// Task 11, шаг 5: запрет генерирующих/изменяющих методов.
final class CodexRPCTests: XCTestCase {
    func testPollAllowedMethodsOnlyReads() {
        XCTAssertTrue(CodexRPC.pollAllowedMethods.contains("initialize"))
        XCTAssertTrue(CodexRPC.pollAllowedMethods.contains("initialized"))
        XCTAssertTrue(CodexRPC.pollAllowedMethods.contains("account/read"))
        XCTAssertTrue(CodexRPC.pollAllowedMethods.contains("account/rateLimits/read"))
        // Генерация и изменения — строго запрещены.
        XCTAssertFalse(CodexRPC.pollAllowedMethods.contains("turn/start"))
        XCTAssertFalse(CodexRPC.pollAllowedMethods.contains("thread/start"))
        XCTAssertFalse(CodexRPC.pollAllowedMethods.contains("account/rateLimitResetCredit/consume"))
        XCTAssertFalse(CodexRPC.pollAllowedMethods.contains("account/login/start"))
        XCTAssertFalse(CodexRPC.pollAllowedMethods.contains("account/logout"))
    }

    func testInitializeMessageFormat() throws {
        let line = CodexRPCCodec.initialize(id: 1).data(using: .utf8)!
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: line) as? [String: Any])
        XCTAssertEqual(object["method"] as? String, "initialize")
        XCTAssertEqual(object["id"] as? Int, 1)
        XCTAssertNil(object["jsonrpc"], "лишний jsonrpc header не добавляется")
        let params = try XCTUnwrap(object["params"] as? [String: Any])
        let clientInfo = try XCTUnwrap(params["clientInfo"] as? [String: Any])
        XCTAssertEqual(clientInfo["name"] as? String, "ai_limits")
    }

    func testAccountReadSendsRefreshTokenFalse() throws {
        let line = CodexRPCCodec.accountRead(id: 2).data(using: .utf8)!
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: line) as? [String: Any])
        let params = try XCTUnwrap(object["params"] as? [String: Any])
        XCTAssertEqual(params["refreshToken"] as? Bool, false)
    }

    func testExtractRateLimitsMatchesByID() throws {
        let line = Data(#"{"id":3,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":31}}}}"#.utf8)
        let extracted = try XCTUnwrap(CodexRPCCodec.extractRateLimits(line: line, expectingID: 3))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: extracted) as? [String: Any])
        XCTAssertNotNil(object["rateLimits"])
    }

    /// Notification (без id) пропускается; чужой id — не наш ответ.
    func testNotificationsAndForeignIDsSkipped() {
        let notification = Data(#"{"method":"turn/completed","params":{}}"#.utf8)
        XCTAssertNil(CodexRPCCodec.extractRateLimits(line: notification, expectingID: 3))
        let foreign = Data(#"{"id":99,"result":{}}"#.utf8)
        XCTAssertNil(CodexRPCCodec.extractRateLimits(line: foreign, expectingID: 3))
        let malformed = Data("not json".utf8)
        XCTAssertNil(CodexRPCCodec.extractRateLimits(line: malformed, expectingID: 3))
    }
}
