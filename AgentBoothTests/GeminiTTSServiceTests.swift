import XCTest
@testable import AgentBooth

final class GeminiTTSServiceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MockURLProtocol.requestHandler = nil
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testSynthesizePrependsSceneDirectionToTTSInput() async throws {
        let session = makeSession()
        let service = GeminiTTSService(session: session)
        let credentialSet = TTSCredentialSet(label: "main", apiKey: "test-key", modelName: "test-model")
        let settings = makeSettings(
            sceneDirection: "深夜帯。静かに、息を多めに。",
            credentialSets: [credentialSet]
        )
        let dialogues = [
            DialogueLine(speaker: "male", text: "こんばんは"),
            DialogueLine(speaker: "female", text: "今夜も始めていきます"),
        ]
        let expectedURL = try XCTUnwrap(
            URL(string: "https://generativelanguage.googleapis.com/v1beta/models/test-model:generateContent?key=test-key")
        )

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url, expectedURL)
            let requestBody = try XCTUnwrap(Self.extractBody(from: request))
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
            let contents = try XCTUnwrap(payload["contents"] as? [[String: Any]])
            let firstContent = try XCTUnwrap(contents.first)
            let parts = try XCTUnwrap(firstContent["parts"] as? [[String: Any]])
            let firstPart = try XCTUnwrap(parts.first)
            let text = try XCTUnwrap(firstPart["text"] as? String)

            XCTAssertEqual(
                text,
                """
                Direction:
                深夜帯。静かに、息を多めに。

                Male: こんばんは
                Female: 今夜も始めていきます
                """
            )

            return try Self.makeSuccessResponse(for: request)
        }

        let result = try await service.synthesize(dialogues: dialogues, settings: settings)
        XCTAssertEqual(result.credentialSetLabelUsed, "main")
        XCTAssertEqual(result.modelUsed, "test-model")
        XCTAssertFalse(result.didUseFallback)
        XCTAssertGreaterThan(result.wavData.count, 44)
    }

    func testSynthesizeOmitsDirectionBlockWhenSceneDirectionIsEmpty() async throws {
        let session = makeSession()
        let service = GeminiTTSService(session: session)
        let settings = makeSettings(
            sceneDirection: "  \n ",
            credentialSets: [TTSCredentialSet(label: "main", apiKey: "test-key", modelName: "test-model")]
        )
        let dialogues = [DialogueLine(speaker: "male", text: "テストです")]

        MockURLProtocol.requestHandler = { request in
            let requestBody = try XCTUnwrap(Self.extractBody(from: request))
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
            let contents = try XCTUnwrap(payload["contents"] as? [[String: Any]])
            let firstContent = try XCTUnwrap(contents.first)
            let parts = try XCTUnwrap(firstContent["parts"] as? [[String: Any]])
            let firstPart = try XCTUnwrap(parts.first)
            let text = try XCTUnwrap(firstPart["text"] as? String)

            XCTAssertEqual(text, "Male: テストです")
            return try Self.makeSuccessResponse(for: request)
        }

        _ = try await service.synthesize(dialogues: dialogues, settings: settings)
    }

    func testSynthesizeFallsThroughToSecondCredentialSetOnRateLimit() async throws {
        let session = makeSession()
        let service = GeminiTTSService(session: session)
        let settings = makeSettings(credentialSets: [
            TTSCredentialSet(label: "main", apiKey: "key-1", modelName: "model-1"),
            TTSCredentialSet(label: "backup", apiKey: "key-2", modelName: "model-2"),
        ])

        MockURLProtocol.requestHandler = { request in
            switch try Self.apiKey(from: request) {
            case "key-1":
                return try Self.makeErrorResponse(
                    for: request,
                    statusCode: 429,
                    body: #"{"error":{"status":"RESOURCE_EXHAUSTED"},"retryDelay":"60s"}"#
                )
            case "key-2":
                return try Self.makeSuccessResponse(for: request)
            default:
                XCTFail("unexpected key")
                return try Self.makeSuccessResponse(for: request)
            }
        }

        let result = try await service.synthesize(dialogues: sampleDialogues(), settings: settings)
        XCTAssertEqual(result.credentialSetLabelUsed, "backup")
        XCTAssertEqual(result.modelUsed, "model-2")
        XCTAssertTrue(result.didUseFallback)
    }

    func testSynthesizeFallsThroughOnAuthError() async throws {
        let session = makeSession()
        let service = GeminiTTSService(session: session)
        let settings = makeSettings(credentialSets: [
            TTSCredentialSet(label: "main", apiKey: "key-1", modelName: "model-1"),
            TTSCredentialSet(label: "backup", apiKey: "key-2", modelName: "model-2"),
        ])

        MockURLProtocol.requestHandler = { request in
            switch try Self.apiKey(from: request) {
            case "key-1":
                return try Self.makeErrorResponse(
                    for: request,
                    statusCode: 401,
                    body: #"{"error":{"message":"invalid key"}}"#
                )
            case "key-2":
                return try Self.makeSuccessResponse(for: request)
            default:
                XCTFail("unexpected key")
                return try Self.makeSuccessResponse(for: request)
            }
        }

        let result = try await service.synthesize(dialogues: sampleDialogues(), settings: settings)
        XCTAssertEqual(result.credentialSetLabelUsed, "backup")
        XCTAssertEqual(result.modelUsed, "model-2")
        XCTAssertTrue(result.didUseFallback)
    }

    func testSynthesizeWritesCueSheetAPICallEvents() async throws {
        let session = makeSession()
        let cueSheetLogger = try makeCueSheetLogger()
        let service = GeminiTTSService(
            session: session,
            successfulCallThrottleInterval: 0,
            cueSheetLogger: cueSheetLogger
        )
        let settings = makeSettings(credentialSets: [
            TTSCredentialSet(label: "main", apiKey: "key-1", modelName: "model-1"),
            TTSCredentialSet(label: "backup", apiKey: "key-2", modelName: "model-2"),
        ])

        MockURLProtocol.requestHandler = { request in
            switch try Self.apiKey(from: request) {
            case "key-1":
                return try Self.makeErrorResponse(
                    for: request,
                    statusCode: 401,
                    body: #"{"error":{"message":"invalid key"}}"#
                )
            case "key-2":
                return try Self.makeSuccessResponse(for: request)
            default:
                XCTFail("unexpected key")
                return try Self.makeSuccessResponse(for: request)
            }
        }

        _ = try await CueSheetLogContext.$currentIndentLevel.withValue(1) {
            try await service.synthesize(dialogues: sampleDialogues(), settings: settings)
        }

        let cueSheetText = try await readCueSheetText(from: cueSheetLogger)
        XCTAssertTrue(cueSheetText.contains("Gemini API呼び出し開始(セット: main / モデル: model-1)"))
        XCTAssertTrue(cueSheetText.contains("Gemini API呼び出し終了(ステータス: 401 / セット: main / モデル: model-1 / 次セット: あり)"))
        XCTAssertTrue(cueSheetText.contains("Gemini API呼び出し開始(セット: backup / モデル: model-2)"))
        XCTAssertTrue(cueSheetText.contains("Gemini API呼び出し終了(ステータス: 200 / セット: backup / モデル: model-2 / フォールバック: 使用)"))
    }

    func testSynthesizeReturnsDailyQuotaExceededWhenAllSetsExhausted() async throws {
        let session = makeSession()
        let service = GeminiTTSService(session: session)
        let settings = makeSettings(credentialSets: [
            TTSCredentialSet(label: "main", apiKey: "key-1", modelName: "model-1"),
            TTSCredentialSet(label: "backup", apiKey: "key-2", modelName: "model-2"),
        ])

        MockURLProtocol.requestHandler = { request in
            try Self.makeErrorResponse(
                for: request,
                statusCode: 429,
                body: #"{"error":{"status":"RESOURCE_EXHAUSTED"},"retryDelay":"7200s"}"#
            )
        }

        await XCTAssertThrowsErrorAsync({
            try await service.synthesize(dialogues: sampleDialogues(), settings: settings)
        }) { error in
            XCTAssertEqual(error as? GeminiTTSServiceError, .dailyQuotaExceeded)
        }
    }

    func testSynthesizeThrowsLastHttpErrorWhenAllSetsFailWithinDailyThreshold() async throws {
        let session = makeSession()
        let service = GeminiTTSService(session: session)
        let settings = makeSettings(credentialSets: [
            TTSCredentialSet(label: "main", apiKey: "key-1", modelName: "model-1"),
            TTSCredentialSet(label: "backup", apiKey: "key-2", modelName: "model-2"),
        ])

        MockURLProtocol.requestHandler = { request in
            switch try Self.apiKey(from: request) {
            case "key-1":
                return try Self.makeErrorResponse(for: request, statusCode: 500, body: #"{"error":"server"}"#)
            case "key-2":
                return try Self.makeErrorResponse(for: request, statusCode: 429, body: #"{"retryDelay":"60s"}"#)
            default:
                XCTFail("unexpected key")
                return try Self.makeSuccessResponse(for: request)
            }
        }

        await XCTAssertThrowsErrorAsync({
            try await service.synthesize(dialogues: sampleDialogues(), settings: settings)
        }) { error in
            guard case .httpError(let statusCode, let bodyText) = error as? GeminiTTSServiceError else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(statusCode, 429)
            XCTAssertTrue(bodyText.contains("60s"))
        }
    }

    func testSynthesizeSkipsEmptyCredentialSets() async throws {
        let session = makeSession()
        let service = GeminiTTSService(session: session)
        let settings = makeSettings(credentialSets: [
            TTSCredentialSet(label: "empty-key", apiKey: "", modelName: "model-1"),
            TTSCredentialSet(label: "empty-model", apiKey: "key-ignored", modelName: ""),
            TTSCredentialSet(label: "active", apiKey: "key-2", modelName: "model-2"),
        ])
        let recorder = RequestRecorder()

        MockURLProtocol.requestHandler = { request in
            recorder.appendKey(try Self.apiKey(from: request))
            return try Self.makeSuccessResponse(for: request)
        }

        let result = try await service.synthesize(dialogues: sampleDialogues(), settings: settings)
        XCTAssertEqual(result.credentialSetLabelUsed, "active")
        XCTAssertEqual(result.modelUsed, "model-2")
        XCTAssertEqual(recorder.requestedKeys, ["key-2"])
    }

    func testSynthesizeThrowsMissingAPIKeyWhenNoActiveSets() async throws {
        let session = makeSession()
        let service = GeminiTTSService(session: session)
        let settings = makeSettings(credentialSets: [
            TTSCredentialSet(label: "empty-key", apiKey: "", modelName: "model-1"),
            TTSCredentialSet(label: "empty-model", apiKey: "key", modelName: ""),
        ])

        await XCTAssertThrowsErrorAsync({
            try await service.synthesize(dialogues: sampleDialogues(), settings: settings)
        }) { error in
            XCTAssertEqual(error as? GeminiTTSServiceError, .missingAPIKey)
        }
    }

    func testSynthesizeSkipsFailedSetInSecondCall() async throws {
        let session = makeSession()
        let service = GeminiTTSService(session: session, successfulCallThrottleInterval: 0)
        let settings = makeSettings(credentialSets: [
            TTSCredentialSet(label: "bad", apiKey: "key-1", modelName: "model-1"),
            TTSCredentialSet(label: "good", apiKey: "key-2", modelName: "model-2"),
        ])
        let recorder = RequestRecorder()

        MockURLProtocol.requestHandler = { request in
            let apiKey = try Self.apiKey(from: request)
            recorder.appendKey(apiKey)
            if apiKey == "key-1" {
                return try Self.makeErrorResponse(for: request, statusCode: 401, body: #"{"error":"invalid key"}"#)
            }
            return try Self.makeSuccessResponse(for: request)
        }

        _ = try await service.synthesize(dialogues: sampleDialogues(), settings: settings)
        _ = try await service.synthesize(dialogues: sampleDialogues(), settings: settings)

        XCTAssertEqual(recorder.count(for: "key-1"), 1)
        XCTAssertEqual(recorder.count(for: "key-2"), 2)
    }

    func testSynthesizeSkipsInvalidResponseSetInSecondCall() async throws {
        let session = makeSession()
        let service = GeminiTTSService(session: session, successfulCallThrottleInterval: 0)
        let settings = makeSettings(credentialSets: [
            TTSCredentialSet(label: "bad", apiKey: "key-1", modelName: "model-1"),
            TTSCredentialSet(label: "good", apiKey: "key-2", modelName: "model-2"),
        ])
        let recorder = RequestRecorder()

        MockURLProtocol.requestHandler = { request in
            let apiKey = try Self.apiKey(from: request)
            recorder.appendKey(apiKey)
            if apiKey == "key-1" {
                let response = try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil))
                let body = #"{"candidates":[{"content":{"parts":[]}}]}"#.data(using: .utf8)!
                return (response, body)
            }
            return try Self.makeSuccessResponse(for: request)
        }

        _ = try await service.synthesize(dialogues: sampleDialogues(), settings: settings)
        _ = try await service.synthesize(dialogues: sampleDialogues(), settings: settings)

        XCTAssertEqual(recorder.count(for: "key-1"), 1)
        XCTAssertEqual(recorder.count(for: "key-2"), 2)
    }

    func testSynthesizeWaitsBeforeFirstAttemptWhenPreviousCallSucceededRecently() async throws {
        let session = makeSession()
        let service = GeminiTTSService(session: session, successfulCallThrottleInterval: 0.05)
        let settings = makeSettings(credentialSets: [
            TTSCredentialSet(label: "main", apiKey: "key-1", modelName: "model-1"),
        ])

        MockURLProtocol.requestHandler = { request in
            try Self.makeSuccessResponse(for: request)
        }

        _ = try await service.synthesize(dialogues: sampleDialogues(), settings: settings)

        let startedAt = Date()
        _ = try await service.synthesize(dialogues: sampleDialogues(), settings: settings)
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertGreaterThanOrEqual(elapsed, 0.04)
    }

    func testSynthesizeDoesNotWaitBetweenFallbackAttempts() async throws {
        let session = makeSession()
        let service = GeminiTTSService(session: session, successfulCallThrottleInterval: 0.05)
        let settings = makeSettings(credentialSets: [
            TTSCredentialSet(label: "bad", apiKey: "key-1", modelName: "model-1"),
            TTSCredentialSet(label: "good", apiKey: "key-2", modelName: "model-2"),
        ])
        let recorder = RequestRecorder()

        MockURLProtocol.requestHandler = { request in
            recorder.appendTime(Date())
            if try Self.apiKey(from: request) == "key-1" {
                return try Self.makeErrorResponse(for: request, statusCode: 401, body: #"{"error":"invalid key"}"#)
            }
            return try Self.makeSuccessResponse(for: request)
        }

        _ = try await service.synthesize(dialogues: sampleDialogues(), settings: settings)

        XCTAssertEqual(recorder.requestTimes.count, 2)
        let delta = recorder.requestTimes[1].timeIntervalSince(recorder.requestTimes[0])
        XCTAssertLessThan(delta, 0.04)
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeSettings(
        sceneDirection: String = "",
        credentialSets: [TTSCredentialSet]
    ) -> AppSettings {
        var settings = AppSettings()
        settings.directionSettings.sceneDirection = sceneDirection
        settings.ttsCredentialSets = credentialSets
        return settings
    }

    private func sampleDialogues() -> [DialogueLine] {
        [
            DialogueLine(speaker: "male", text: "こんばんは"),
            DialogueLine(speaker: "female", text: "テストです"),
        ]
    }

    private func makeCueSheetLogger() throws -> ShowCueSheetLogger {
        let directoryURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        return ShowCueSheetLogger(sessionDirectoryURL: directoryURL)
    }

    private func readCueSheetText(from logger: ShowCueSheetLogger) async throws -> String {
        let fileURL = try await logger.cueSheetFileURL()
        return try String(contentsOf: fileURL, encoding: .utf8)
    }

    private static func makeSuccessResponse(for request: URLRequest) throws -> (HTTPURLResponse, Data) {
        let response = try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil))
        let body = """
        {"candidates":[{"content":{"parts":[{"inlineData":{"data":"AAAA","mimeType":"audio/pcm"}}]}}]}
        """.data(using: .utf8)!
        return (response, body)
    }

    private static func makeErrorResponse(
        for request: URLRequest,
        statusCode: Int,
        body: String
    ) throws -> (HTTPURLResponse, Data) {
        let response = try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil))
        return (response, body.data(using: .utf8)!)
    }

    private static func apiKey(from request: URLRequest) throws -> String {
        let url = try XCTUnwrap(request.url)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let apiKey = components.queryItems?.first(where: { $0.name == "key" })?.value
        return try XCTUnwrap(apiKey)
    }

    private static func extractBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }

        let bufferSize = 1024
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let readCount = stream.read(buffer, maxLength: bufferSize)
            guard readCount > 0 else { break }
            data.append(buffer, count: readCount)
        }
        return data.isEmpty ? nil : data
    }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    static var requestHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            XCTFail("requestHandler が未設定")
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: () async throws -> T,
    _ errorHandler: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("expected error")
    } catch {
        errorHandler(error)
    }
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String] = []
    private var times: [Date] = []

    var requestedKeys: [String] {
        lock.withLock { keys }
    }

    var requestTimes: [Date] {
        lock.withLock { times }
    }

    func appendKey(_ key: String) {
        lock.withLock {
            keys.append(key)
        }
    }

    func appendTime(_ time: Date) {
        lock.withLock {
            times.append(time)
        }
    }

    func count(for key: String) -> Int {
        lock.withLock {
            keys.filter { $0 == key }.count
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
