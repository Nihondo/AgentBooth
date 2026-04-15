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
        let settings = makeSettings(sceneDirection: "深夜帯。静かに、息を多めに。")
        let dialogues = [
            DialogueLine(speaker: "male", text: "こんばんは"),
            DialogueLine(speaker: "female", text: "今夜も始めていきます"),
        ]
        let expectedURL = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(settings.geminiTTSModel):generateContent?key=\(settings.geminiAPIKey)")!

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

            let response = HTTPURLResponse(url: expectedURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = """
            {"candidates":[{"content":{"parts":[{"inlineData":{"data":"AAAA","mimeType":"audio/pcm"}}]}}]}
            """.data(using: .utf8)!
            return (response, body)
        }

        let result = try await service.synthesize(dialogues: dialogues, settings: settings)
        XCTAssertEqual(result.modelUsed, settings.geminiTTSModel)
        XCTAssertGreaterThan(result.wavData.count, 44)
    }

    func testSynthesizeOmitsDirectionBlockWhenSceneDirectionIsEmpty() async throws {
        let session = makeSession()
        let service = GeminiTTSService(session: session)
        let settings = makeSettings(sceneDirection: "  \n ")
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

            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = """
            {"candidates":[{"content":{"parts":[{"inlineData":{"data":"AAAA","mimeType":"audio/pcm"}}]}}]}
            """.data(using: .utf8)!
            return (response, body)
        }

        _ = try await service.synthesize(dialogues: dialogues, settings: settings)
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeSettings(sceneDirection: String) -> AppSettings {
        var settings = AppSettings()
        settings.geminiAPIKey = "test-key"
        settings.geminiTTSModel = "gemini-2.5-flash-preview-tts"
        settings.directionSettings.sceneDirection = sceneDirection
        return settings
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
