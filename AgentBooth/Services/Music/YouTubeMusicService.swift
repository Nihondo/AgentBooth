// MARK: - YouTubeMusicService.swift
// MusicService プロトコルの YouTube Music 実装。
// YouTubeMusicWebViewStore が保持する WKWebView を通じて
// APIFetcher（プレイリスト/トラック取得）と PlayerController（再生制御）に処理を委譲する。

import Foundation
import WebKit

// MARK: - エラー型

enum YouTubeMusicServiceError: LocalizedError {
    case notLoggedIn
    case unsupportedOperation

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "YouTube Music にログインしていません。設定からログインしてください。"
        case .unsupportedOperation:
            return "この操作は YouTube Music では未対応です。"
        }
    }
}

// MARK: - Service

/// YouTube Music の MusicService 実装。
/// @MainActor で隔離し WKWebView を安全に操作する。
@MainActor
final class YouTubeMusicService: MusicService, @unchecked Sendable {
    let serviceKind: MusicServiceKind = .youtubeMusic

    private let store: YouTubeMusicWebViewStore
    private let apiFetcher: YouTubeMusicAPIFetcher
    private let playerController: YouTubeMusicPlayerController

    /// 直近に選択されたプレイリスト ID（再生時のコンテキスト用）
    private var currentPlaylistId: String = ""

    init(store: YouTubeMusicWebViewStore) {
        self.store = store
        self.apiFetcher = YouTubeMusicAPIFetcher()
        self.playerController = YouTubeMusicPlayerController()
    }

    // MARK: - MusicService プロトコル

    /// ユーザーのプレイリスト名一覧を返す
    func fetchPlaylists() async throws -> [String] {
        try requireLoggedIn()
        let items = try await apiFetcher.fetchPlaylists(using: store.playbackWebView)
        return items.map(\.title)
    }

    /// プレイリスト名に対応するトラック一覧を返す
    func fetchTracks(in playlistName: String) async throws -> [TrackInfo] {
        try requireLoggedIn()
        // プレイリスト一覧から名前に一致する ID を取得
        let playlists = try await apiFetcher.fetchPlaylists(using: store.playbackWebView)
        guard let playlist = playlists.first(where: { $0.title == playlistName }) else {
            return []
        }
        currentPlaylistId = playlist.id
        let items = try await apiFetcher.fetchTracks(
            playlistId: playlist.id,
            using: store.playbackWebView
        )
        return items.map { item in
            TrackInfo(
                name: item.title,
                artist: item.artist,
                album: item.album,
                durationSeconds: item.durationSeconds,
                playlistName: playlistName,
                serviceID: item.videoId,
                artworkURL: item.thumbnailURL
            )
        }
    }

    /// 指定トラックを再生する
    func play(track: TrackInfo) async throws {
        try requireLoggedIn()
        guard !track.serviceID.isEmpty else {
            throw YouTubeMusicServiceError.unsupportedOperation
        }
        let listId = track.playlistName.isEmpty ? currentPlaylistId : currentPlaylistId
        try await playerController.play(
            videoId: track.serviceID,
            playlistId: listId,
            using: store.playbackWebView
        )
    }

    func stopPlayback() async {
        await playerController.stop(using: store.playbackWebView)
    }

    func pausePlayback() async {
        await playerController.pause(using: store.playbackWebView)
    }

    func resumePlayback() async {
        await playerController.resume(using: store.playbackWebView)
    }

    func setVolume(level: Int) async {
        await playerController.setVolume(level, using: store.playbackWebView)
    }

    func fetchVolume() async -> Int {
        await playerController.fetchVolume(using: store.playbackWebView)
    }

    func fetchCurrentTrack() async throws -> TrackInfo? {
        await playerController.fetchCurrentTrack(
            playlistName: "",
            using: store.playbackWebView
        )
    }

    func fetchIsPlaying() async -> Bool {
        await playerController.fetchIsPlaying(using: store.playbackWebView)
    }

    func fetchPlaybackPosition() async -> Double {
        await playerController.fetchPlaybackPosition(using: store.playbackWebView)
    }

    func seekToPosition(_ seconds: Double) async {
        await playerController.seekToPosition(seconds, using: store.playbackWebView)
    }

    // MARK: - プライベート

    private func requireLoggedIn() throws {
        guard store.isLoggedIn else {
            throw YouTubeMusicServiceError.notLoggedIn
        }
    }
}
