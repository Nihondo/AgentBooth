import XCTest
@testable import AgentBooth

@MainActor
final class MainViewModelTests: XCTestCase {
    func testLoadPlaylistsAndStartFlow() async throws {
        let trackList = [
            TrackInfo(name: "Song A", artist: "Artist A", album: "Album A", durationSeconds: 0, playlistName: "Favorites"),
        ]
        let musicService = FakeMusicService(playlists: ["Favorites"], tracksByPlaylist: ["Favorites": trackList])
        let factory = FakeServiceFactory(musicService: musicService)
        let suiteName = "AgentBoothTests.\(UUID().uuidString)"
        let settingsStore = AppSettingsStore(
            userDefaults: UserDefaults(suiteName: suiteName)!,
            keychainStore: KeychainStore(serviceName: suiteName)
        )
        let viewModel = MainViewModel(settingsStore: settingsStore, serviceFactory: factory)

        await viewModel.loadPlaylists()
        XCTAssertEqual(viewModel.availablePlaylists, ["Favorites"])
        XCTAssertEqual(viewModel.selectedPlaylistName, "Favorites")

        viewModel.handlePrimaryControl()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(viewModel.radioState.phase == .opening || viewModel.radioState.phase == .intro || viewModel.radioState.phase == .playing || viewModel.radioState.phase == .closing || viewModel.radioState.phase == .idle)
    }

    func testStartFlowSurfacesTTSErrorMessage() async throws {
        let trackList = [
            TrackInfo(name: "Song A", artist: "Artist A", album: "Album A", durationSeconds: 0, playlistName: "Favorites"),
        ]
        let musicService = FakeMusicService(playlists: ["Favorites"], tracksByPlaylist: ["Favorites": trackList])
        let ttsService = FailingTTSService(error: GeminiTTSServiceError.invalidResponse(" テスト失敗"))
        let factory = FakeServiceFactory(musicService: musicService, ttsService: ttsService)
        let suiteName = "AgentBoothTests.\(UUID().uuidString)"
        let settingsStore = AppSettingsStore(
            userDefaults: UserDefaults(suiteName: suiteName)!,
            keychainStore: KeychainStore(serviceName: suiteName)
        )
        let viewModel = MainViewModel(settingsStore: settingsStore, serviceFactory: factory)

        await viewModel.loadPlaylists()
        viewModel.handlePrimaryControl()

        for _ in 0..<20 {
            try await Task.sleep(nanoseconds: 50_000_000)
            if let errorMessage = viewModel.radioState.errorMessage, !errorMessage.isEmpty {
                XCTAssertTrue(errorMessage.contains("オープニング"))
                XCTAssertTrue(errorMessage.contains("テスト失敗"))
                XCTAssertFalse(viewModel.radioState.isRunning)
                return
            }
        }

        XCTFail("TTS エラーが UI 状態に反映されませんでした。")
    }
}
