import XCTest
@testable import AgentBooth

final class SpotifyDOMModelsTests: XCTestCase {
    func testMusicServiceKindIncludesSpotify() {
        XCTAssertTrue(MusicServiceKind.allCases.contains(.spotify))
        XCTAssertEqual(MusicServiceKind.spotify.displayName, "Spotify")
    }

    func testSpotifyTrackItemMapsPlayableTrackToTrackInfo() {
        let item = SpotifyTrackItem(
            title: "Song A",
            artist: "Artist A",
            album: "Album A",
            durationSeconds: 215,
            href: "https://open.spotify.com/track/123",
            playlistURL: "https://open.spotify.com/playlist/456",
            isPlayable: true,
            contentType: "track",
            artworkURL: "https://i.scdn.co/image/abc123"
        )

        let track = item.toTrackInfo(playlistName: "Favorites")
        XCTAssertEqual(track?.name, "Song A")
        XCTAssertEqual(track?.artist, "Artist A")
        XCTAssertEqual(track?.playlistName, "Favorites")
        XCTAssertEqual(track?.serviceID, "https://open.spotify.com/track/123")
        XCTAssertEqual(track?.artworkURL, "https://i.scdn.co/image/abc123")
    }

    func testSpotifyTrackItemExcludesNonTrackContent() {
        let episode = SpotifyTrackItem(
            title: "Episode A",
            artist: "Host",
            album: "",
            durationSeconds: 1200,
            href: "https://open.spotify.com/episode/123",
            playlistURL: "https://open.spotify.com/playlist/456",
            isPlayable: true,
            contentType: "episode",
            artworkURL: nil
        )
        let localFile = SpotifyTrackItem(
            title: "Local Song",
            artist: "Artist",
            album: "",
            durationSeconds: 180,
            href: "",
            playlistURL: "https://open.spotify.com/playlist/456",
            isPlayable: false,
            contentType: "local",
            artworkURL: nil
        )
        let unavailable = SpotifyTrackItem(
            title: "Missing Song",
            artist: "Artist",
            album: "",
            durationSeconds: 180,
            href: "https://open.spotify.com/track/789",
            playlistURL: "https://open.spotify.com/playlist/456",
            isPlayable: false,
            contentType: "track",
            artworkURL: nil
        )

        XCTAssertNil(episode.toTrackInfo(playlistName: "Favorites"))
        XCTAssertNil(localFile.toTrackInfo(playlistName: "Favorites"))
        XCTAssertNil(unavailable.toTrackInfo(playlistName: "Favorites"))
    }

    func testSpotifyMusicServiceErrorMessages() {
        XCTAssertEqual(
            SpotifyMusicServiceError.domNotMatched("selector missing").errorDescription,
            "Spotify Web UI の構造変更で取得失敗: selector missing"
        )
        XCTAssertEqual(
            SpotifyMusicServiceError.notLoggedIn.errorDescription,
            "Spotify にログインしていません。設定からログインしてください。"
        )
    }

    func testFetchSidebarPlaylistsScriptIncludesTitleNodeFallback() {
        XCTAssertTrue(
            SpotifyDOMScripts.fetchSidebarPlaylists.contains(#"p[data-encore-id="listRowTitle"][id^="listrow-title-spotify:playlist:"]"#)
        )
        XCTAssertTrue(
            SpotifyDOMScripts.fetchSidebarPlaylists.contains(#"https://open.spotify.com/playlist/"#)
        )
        XCTAssertTrue(
            SpotifyDOMScripts.scrollSidebarPlaylists.contains(#"[data-testid="left-sidebar"]"#)
        )
    }

    func testPlaylistTrackScriptsScopeRowsToNamedTracklistGrid() {
        let readyScript = SpotifyDOMScripts.checkTrackRowsReady(playlistName: "プレイリスト #2")
        let fetchScript = SpotifyDOMScripts.fetchPlaylistTracks(playlistName: "プレイリスト #2")
        let playScript = SpotifyDOMScripts.playTrack(
            trackHref: "https://open.spotify.com/track/123",
            trackName: "Song",
            artistName: "Artist",
            playlistName: "プレイリスト #2"
        )

        XCTAssertTrue(readyScript.contains(#"data-testid="playlist-tracklist""#))
        XCTAssertTrue(fetchScript.contains(#"data-testid="playlist-tracklist""#))
        XCTAssertTrue(fetchScript.contains(#"aria-label"#))
        XCTAssertTrue(playScript.contains(#"data-testid="playlist-tracklist""#))
        XCTAssertTrue(playScript.contains("プレイリスト #2"))
    }

    func testVolumeScriptsSupportRangeNormalizationAndPointerSequence() {
        let setVolumeScript = SpotifyDOMScripts.setVolume(42)
        XCTAssertTrue(setVolumeScript.contains("denormalizeSliderValue"))
        XCTAssertTrue(setVolumeScript.contains("dispatchPointerSequence"))
        XCTAssertTrue(setVolumeScript.contains(#"data-testid="progress-bar""#))
        XCTAssertTrue(setVolumeScript.contains("findVolumeProgressBar"))
        XCTAssertTrue(SpotifyDOMScripts.fetchVolume.contains("describeVolumeControl"))
        XCTAssertTrue(SpotifyDOMScripts.fetchVolume.contains("readProgressBarLevel"))
    }

    func testFakeMusicServiceSupportsSpotifyKind() async throws {
        let service = FakeMusicService(serviceKind: .spotify)
        XCTAssertEqual(service.serviceKind, .spotify)
    }
}
