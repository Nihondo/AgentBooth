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

    func testSaveAndLoadNarrationAudioRoundTrips() async throws {
        let (store, _) = makeStore()
        let wavData = Data([0x01, 0x02, 0x03])

        await store.saveNarrationAudio(wavData, fingerprint: "abc123")
        let loaded = await store.loadNarrationAudio(fingerprint: "abc123")

        XCTAssertEqual(loaded, wavData)
    }

    func testLoadNarrationAudioReturnsNilForUnknownFingerprint() async throws {
        let (store, _) = makeStore()
        let loaded = await store.loadNarrationAudio(fingerprint: "unknown")
        XCTAssertNil(loaded)
    }

    func testPruneNarrationAudioDeletesOnlyUnkeptFingerprints() async throws {
        let (store, directoryURL) = makeStore()

        await store.saveNarrationAudio(Data([0x01]), fingerprint: "keep-me")
        await store.saveNarrationAudio(Data([0x02]), fingerprint: "drop-me")

        await store.pruneNarrationAudio(keeping: ["keep-me"])

        let keptAudio = await store.loadNarrationAudio(fingerprint: "keep-me")
        let droppedAudio = await store.loadNarrationAudio(fingerprint: "drop-me")
        XCTAssertNotNil(keptAudio)
        XCTAssertNil(droppedAudio)

        let audioDirectoryContents = try FileManager.default.contentsOfDirectory(
            at: directoryURL.appendingPathComponent("audio", isDirectory: true),
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(audioDirectoryContents.count, 1)
    }

    /// `clear()` は台本セッションのアーカイブに加えて音声も掃除するが、アーカイブ先には音声を残さない
    /// （音声は fingerprint ベースの独立キャッシュであり、台本 JSON のアーカイブとは別ライフサイクル）。
    /// アーカイブされる JSON ファイルが1個であることは既存テスト
    /// `testClearArchivesActiveCacheInsteadOfDeletingIt` が検証済みなので、ここでは音声ディレクトリのみを見る。
    func testClearAlsoDeletesAllNarrationAudio() async throws {
        let (store, directoryURL) = makeStore()
        await store.save(makePersistedScriptSession())
        await store.saveNarrationAudio(Data([0x01]), fingerprint: "opening-fingerprint")
        await store.saveNarrationAudio(Data([0x02]), fingerprint: "closing-fingerprint")

        await store.clear()

        let openingAudio = await store.loadNarrationAudio(fingerprint: "opening-fingerprint")
        let closingAudio = await store.loadNarrationAudio(fingerprint: "closing-fingerprint")
        XCTAssertNil(openingAudio)
        XCTAssertNil(closingAudio)

        let audioDirectoryContents = try? FileManager.default.contentsOfDirectory(
            at: directoryURL.appendingPathComponent("audio", isDirectory: true),
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(audioDirectoryContents?.count ?? 0, 0)
    }

    private func makeStore() -> (PreGeneratedScriptStore, URL) {
        let directoryURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let fileURL = directoryURL.appendingPathComponent("pregenerated_session.json")
        return (PreGeneratedScriptStore(fileURL: fileURL), directoryURL)
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
