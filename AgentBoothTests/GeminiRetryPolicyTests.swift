import XCTest
@testable import AgentBooth

final class GeminiRetryPolicyTests: XCTestCase {
    func testRetryDelayParsingForStructuredBody() {
        let bodyText = #"{"retryDelay":"50741s"}"#
        let policy = GeminiRetryPolicy()

        XCTAssertEqual(policy.parseRetryDelay(from: bodyText), 50_741)
    }

    func testDailyQuotaDetectionUsesRetryThreshold() {
        let bodyText = #"Please retry in 14h5m41s"#
        let policy = GeminiRetryPolicy()

        XCTAssertTrue(policy.isDailyQuotaExhausted(bodyText: bodyText))
        XCTAssertTrue(policy.isRateLimited(statusCode: 429, bodyText: bodyText))
    }
}
