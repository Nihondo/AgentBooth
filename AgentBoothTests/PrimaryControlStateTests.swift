import XCTest
@testable import AgentBooth

final class PrimaryControlStateTests: XCTestCase {
    func testPrimaryControlStateTransitions() {
        var state = RadioState()
        XCTAssertEqual(state.primaryControlState, .start)

        state.isRunning = true
        XCTAssertEqual(state.primaryControlState, .pause)

        state.isPaused = true
        XCTAssertEqual(state.primaryControlState, .resume)

        state.isPaused = false
        XCTAssertEqual(state.primaryControlState, .pause)

        state.isRunning = false
        XCTAssertEqual(state.primaryControlState, .start)
    }
}
