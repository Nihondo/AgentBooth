import XCTest
@testable import AgentBooth

final class PreGeneratedScriptStoreTests: XCTestCase {
    func testClearArchivesActiveCacheInsteadOfDeletingIt() async throws {
        let directoryURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directoryURL)
        }

        let activeFileURL = directoryURL.appendingPathComponent("pregenerated_session.json")
        let store = PreGeneratedScriptStore(fileURL: activeFileURL)
        let session = makePersistedScriptSession()

        await store.save(session)
        XCTAssertTrue(FileManager.default.fileExists(atPath: activeFileURL.path))

        await store.clear()

        XCTAssertFalse(FileManager.default.fileExists(atPath: activeFileURL.path))
        let loadedSession = await store.load()
        XCTAssertNil(loadedSession)

        let archivedFiles = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(archivedFiles.count, 1)
        XCTAssertTrue(archivedFiles[0].lastPathComponent.hasPrefix("pregenerated_session_"))

        let archivedData = try Data(contentsOf: archivedFiles[0])
        let archivedSession = try JSONDecoder().decode(PersistedScriptSession.self, from: archivedData)
        XCTAssertEqual(archivedSession, session)
    }

    private func makePersistedScriptSession() -> PersistedScriptSession {
        let track = TrackInfo(
            name: "Song A",
            artist: "Artist A",
            album: "Album A",
            playlistName: "Favorites"
        )
        let script = RadioScript(
            segmentType: "opening",
            dialogues: [DialogueLine(speaker: "male", text: "hello")],
            summaryBullets: ["topic"],
            track: track
        )
        return PersistedScriptSession(
            playlistName: "Favorites",
            trackFingerprint: track.id,
            tracks: [track],
            segments: [
                PersistedSegment(
                    key: "opening",
                    script: script,
                    narrationSettings: AppSettings().strippingSecrets()
                ),
            ],
            savedAt: Date(timeIntervalSince1970: 0)
        )
    }
}
