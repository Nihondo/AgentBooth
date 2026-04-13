import Foundation
import WebKit

/// Spotify の DOM 制御エラー。
enum SpotifyMusicServiceError: LocalizedError {
    case notLoggedIn
    case pageNotReady
    case playlistNotFound(String)
    case domNotMatched(String)
    case unsupportedOperation(String)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Spotify にログインしていません。設定からログインしてください。"
        case .pageNotReady:
            return "Spotify Web Player の読み込みが完了していません。"
        case .playlistNotFound(let playlistName):
            return "Spotify プレイリストが見つかりません: \(playlistName)"
        case .domNotMatched(let message):
            return "Spotify Web UI の構造変更で取得失敗: \(message)"
        case .unsupportedOperation(let message):
            return message
        }
    }
}

/// Spotify の `MusicService` 実装。
@MainActor
final class SpotifyMusicService: MusicService, @unchecked Sendable {
    let serviceKind: MusicServiceKind = .spotify

    private let store: SpotifyWebViewStore
    private let scriptRunner: SpotifyScriptRunner
    private var playlistByName: [String: SpotifyPlaylistItem] = [:]
    private var currentPlaylist: SpotifyPlaylistItem?
    private var currentTracks: [SpotifyTrackItem] = []

    /// Spotify Web Player を制御するサービスを生成する。
    init(store: SpotifyWebViewStore, scriptRunner: SpotifyScriptRunner = SpotifyScriptRunner()) {
        self.store = store
        self.scriptRunner = scriptRunner
    }

    /// Spotify サイドバーのプレイリスト一覧を返す。
    func fetchPlaylists() async throws -> [String] {
        try await ensureLoggedInAndReady()
        try await navigatePlaybackWebView(to: SpotifyWebViewStore.libraryURL)
        let items = try await fetchSidebarPlaylistsWithScroll()
        let filteredItems = items.filter { !$0.title.isEmpty && !$0.href.isEmpty }
        print("🎵 [Spotify] fetched playlists:", filteredItems.count)
        playlistByName = Dictionary(uniqueKeysWithValues: filteredItems.map { ($0.title, $0) })
        return filteredItems.map(\.title)
    }

    /// 指定プレイリストのトラック一覧を返す。
    func fetchTracks(in playlistName: String) async throws -> [TrackInfo] {
        try await ensureLoggedInAndReady()
        let playlist = try await resolvePlaylist(named: playlistName)
        try await navigatePlaybackWebView(to: playlist.href)
        try await waitUntilTrackRowsReady(in: playlist.title)
        let items = try await scriptRunner.decodeJSONScript(
            [SpotifyTrackItem].self,
            script: SpotifyDOMScripts.fetchPlaylistTracks(playlistName: playlist.title),
            webView: store.playbackWebView
        )
        print("🎵 [Spotify] fetched track rows:", items.count)
        currentPlaylist = playlist
        currentTracks = items
        return items.compactMap { $0.toTrackInfo(playlistName: playlistName) }
    }

    /// 対象トラックをプレイリスト上で再特定して再生する。
    func play(track: TrackInfo) async throws {
        try await ensureLoggedInAndReady()
        let playlist = try await resolvePlaylist(named: track.playlistName)
        try await navigatePlaybackWebView(to: playlist.href)
        try await waitUntilTrackRowsReady(in: playlist.title)
        _ = try await scriptRunner.runJSONScript(
            SpotifyDOMScripts.playTrack(
                trackHref: track.serviceID,
                trackName: track.name,
                artistName: track.artist,
                playlistName: playlist.title
            ),
            webView: store.playbackWebView
        )
        currentPlaylist = playlist
        try await waitForPlaybackState(isPlaying: true)
    }

    /// Spotify 再生を停止する。MVP では pause 相当。
    func stopPlayback() async {
        await pausePlayback()
    }

    /// Spotify 再生を一時停止する。
    func pausePlayback() async {
        _ = try? await scriptRunner.runJSONScript(
            SpotifyDOMScripts.pausePlayback,
            webView: store.playbackWebView
        )
    }

    /// Spotify 再生を再開する。
    func resumePlayback() async {
        _ = try? await scriptRunner.runJSONScript(
            SpotifyDOMScripts.resumePlayback,
            webView: store.playbackWebView
        )
    }

    /// Spotify 音量を設定する。
    func setVolume(level: Int) async {
        let clampedLevel = max(0, min(100, level))
        _ = try? await scriptRunner.runJSONScript(
            SpotifyDOMScripts.setVolume(clampedLevel),
            webView: store.playbackWebView
        )
    }

    /// Spotify 音量を返す。
    func fetchVolume() async -> Int {
        struct VolumeResponse: Decodable {
            let level: Int
        }

        guard let response = try? await scriptRunner.decodeJSONScript(
            VolumeResponse.self,
            script: SpotifyDOMScripts.fetchVolume,
            webView: store.playbackWebView
        ) else {
            return 0
        }
        return response.level
    }

    /// 現在再生中のトラックを返す。
    func fetchCurrentTrack() async throws -> TrackInfo? {
        let state = try await fetchPlayerState()
        guard let track = state.track else { return nil }
        return TrackInfo(
            name: track.title,
            artist: track.artist,
            album: "",
            durationSeconds: 0,
            playlistName: currentPlaylist?.title ?? "",
            serviceID: track.href,
            artworkURL: track.artworkURL
        )
    }

    /// 現在再生中かを返す。
    func fetchIsPlaying() async -> Bool {
        ((try? await fetchPlayerState())?.isPlaying) ?? false
    }

    /// 現在の再生位置を秒単位で返す。
    func fetchPlaybackPosition() async -> Double {
        struct PositionResponse: Decodable { let positionSeconds: Double }
        guard let response = try? await scriptRunner.decodeJSONScript(
            PositionResponse.self,
            script: SpotifyDOMScripts.fetchPlaybackPosition,
            webView: store.playbackWebView
        ) else { return 0 }
        return response.positionSeconds
    }

    /// 指定秒数へシークする。
    func seekToPosition(_ seconds: Double) async {
        _ = try? await scriptRunner.runJSONScript(
            SpotifyDOMScripts.seekToPosition(seconds),
            webView: store.playbackWebView
        )
    }

    private func ensureLoggedInAndReady() async throws {
        await store.refreshLoginStatus()
        guard store.isLoggedIn else {
            throw SpotifyMusicServiceError.notLoggedIn
        }
        guard store.playbackWebView.url?.host == SpotifyWebViewStore.targetHost else {
            throw SpotifyMusicServiceError.pageNotReady
        }
    }

    private func resolvePlaylist(named playlistName: String) async throws -> SpotifyPlaylistItem {
        if let playlist = playlistByName[playlistName] {
            return playlist
        }
        _ = try await fetchPlaylists()
        if let playlist = playlistByName[playlistName] {
            return playlist
        }
        throw SpotifyMusicServiceError.playlistNotFound(playlistName)
    }

    private func fetchSidebarPlaylistsWithScroll() async throws -> [SpotifyPlaylistItem] {
        var bestItems: [SpotifyPlaylistItem] = []
        var stableCount = 0
        for _ in 0..<14 {
            let items = try await scriptRunner.decodeSynchronousJSONScript(
                [SpotifyPlaylistItem].self,
                script: SpotifyDOMScripts.fetchSidebarPlaylists,
                webView: store.playbackWebView
            )
            if items.count > bestItems.count {
                bestItems = items
                stableCount = 0
            } else if !items.isEmpty && items.count == bestItems.count {
                stableCount += 1
            }
            if !bestItems.isEmpty && stableCount >= 2 {
                return bestItems
            }
            _ = try? await scriptRunner.runSynchronousJSONScript(
                SpotifyDOMScripts.scrollSidebarPlaylists,
                webView: store.playbackWebView
            )
            try? await Task.sleep(nanoseconds: 180_000_000)
        }
        if !bestItems.isEmpty {
            return bestItems
        }
        let items = try await scriptRunner.decodeSynchronousJSONScript(
            [SpotifyPlaylistItem].self,
            script: SpotifyDOMScripts.fetchSidebarPlaylists,
            webView: store.playbackWebView
        )
        if !items.isEmpty {
            return items
        }
        throw SpotifyMusicServiceError.domNotMatched("Spotify プレイリスト title node が見つかりませんでした。")
    }

    private func navigatePlaybackWebView(to value: String) async throws {
        guard let url = URL(string: value) else {
            throw SpotifyMusicServiceError.domNotMatched("URL を解釈できません。")
        }
        try await navigatePlaybackWebView(to: url)
    }

    private func navigatePlaybackWebView(to url: URL) async throws {
        if store.playbackWebView.url?.absoluteString != url.absoluteString {
            store.playbackWebView.load(URLRequest(url: url))
        }
        try await waitUntil(timeoutNanoseconds: 10_000_000_000) {
            self.store.playbackWebView.url?.host == SpotifyWebViewStore.targetHost &&
            (self.store.playbackWebView.url?.absoluteString ?? "").contains(url.path)
        }
    }

    private func waitUntilTrackRowsReady(in playlistName: String) async throws {
        struct ReadyResponse: Decodable {
            let rowCount: Int
            let currentURL: String
        }

        try await waitUntil(timeoutNanoseconds: 10_000_000_000) {
            if let response = try? await self.scriptRunner.decodeJSONScript(
                ReadyResponse.self,
                script: SpotifyDOMScripts.checkTrackRowsReady(playlistName: playlistName),
                webView: self.store.playbackWebView
            ) {
                return response.rowCount > 0
            }
            return false
        }
    }

    private func waitForPlaybackState(isPlaying expectedValue: Bool) async throws {
        try await waitUntil(timeoutNanoseconds: 4_000_000_000) {
            (try? await self.fetchPlayerState().isPlaying) == expectedValue
        }
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64,
        condition: @escaping () async -> Bool
    ) async throws {
        let intervalNanoseconds: UInt64 = 250_000_000
        let iterations = max(1, Int(timeoutNanoseconds / intervalNanoseconds))
        for _ in 0..<iterations {
            if await condition() {
                return
            }
            try? await Task.sleep(nanoseconds: intervalNanoseconds)
        }
        throw SpotifyMusicServiceError.domNotMatched("タイムアウトしました。")
    }

    private func fetchPlayerState() async throws -> SpotifyPlayerStateResponse {
        do {
            return try await scriptRunner.decodeJSONScript(
                SpotifyPlayerStateResponse.self,
                script: SpotifyDOMScripts.fetchPlayerState,
                webView: store.playbackWebView
            )
        } catch let error as SpotifyScriptRunnerError {
            throw SpotifyMusicServiceError.domNotMatched(error.localizedDescription)
        } catch {
            throw SpotifyMusicServiceError.domNotMatched(error.localizedDescription)
        }
    }
}

private struct SpotifyPlayerStateResponse: Decodable {
    let isPlaying: Bool
    let track: SpotifyPlayerTrackResponse?
}

private struct SpotifyPlayerTrackResponse: Decodable {
    let href: String
    let title: String
    let artist: String
    let artworkURL: String?
}
