import XCTest
@testable import AgentBooth

final class AppleMusicServiceTests: XCTestCase {
    func testPlayStopsBeforePlayingTrackAndDoesNotSetPlayerPositionDirectly() async throws {
        let executor = ScriptRecordingAppleScriptExecutor()
        let service = AppleMusicService(appleScriptExecutor: executor)
        let track = TrackInfo(
            name: "Song A",
            artist: "Artist A",
            album: "Album A",
            playlistName: "Favorites"
        )

        try await service.play(track: track)

        let script = try XCTUnwrap(executor.scripts.first)
        XCTAssertTrue(script.contains("stop"))
        XCTAssertTrue(script.contains("play item 1 of found_tracks"))
        XCTAssertFalse(script.contains("set player position to 0"))
    }
}

private final class ScriptRecordingAppleScriptExecutor: AppleScriptExecuting, @unchecked Sendable {
    private(set) var scripts: [String] = []

    func run(script: String) throws -> String {
        scripts.append(script)
        return ""
    }
}
