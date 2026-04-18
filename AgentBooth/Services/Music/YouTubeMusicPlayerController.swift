// MARK: - YouTubeMusicPlayerController.swift
// YouTube Music の再生・一時停止・音量制御・現在トラック取得を担当する。
// JS で video 要素を直接操作し、MusicService プロトコルの再生系メソッドを実装する。

import Foundation
import WebKit

/// YouTube Music 再生制御
final class YouTubeMusicPlayerController {
    private let scriptRunner: YouTubeMusicScriptRunner

    init(scriptRunner: YouTubeMusicScriptRunner = YouTubeMusicScriptRunner()) {
        self.scriptRunner = scriptRunner
    }

    // MARK: - 再生ナビゲーション

    /// 指定曲を YouTube Music で再生する（URL ナビゲーション）
    @MainActor
    func play(videoId: String, playlistId: String, using webView: WKWebView) async throws {
        let script = YouTubeMusicJSScripts.playTrack(videoId: videoId, playlistId: playlistId)
        _ = try? await scriptRunner.runJSONScript(script, webView: webView)
        // ナビゲーション後、目的の videoId を再生する video が利用可能になるまで最大 5 秒待機
        try await waitForPlaybackTarget(videoId: videoId, webView: webView, timeoutSeconds: 5)
    }

    // MARK: - 再生制御

    @MainActor
    func stop(using webView: WKWebView) async {
        _ = try? await scriptRunner.runJSONScript(
            YouTubeMusicJSScripts.stopPlayback,
            webView: webView
        )
    }

    @MainActor
    func pause(using webView: WKWebView) async {
        _ = try? await scriptRunner.runJSONScript(
            YouTubeMusicJSScripts.pausePlayback,
            webView: webView
        )
    }

    @MainActor
    func resume(using webView: WKWebView) async {
        _ = try? await scriptRunner.runJSONScript(
            YouTubeMusicJSScripts.resumePlayback,
            webView: webView
        )
    }

    // MARK: - 音量

    @MainActor
    func setVolume(_ level: Int, using webView: WKWebView) async {
        _ = try? await scriptRunner.runJSONScript(
            YouTubeMusicJSScripts.setVolume(level),
            webView: webView
        )
    }

    @MainActor
    func fetchVolume(using webView: WKWebView) async -> Int {
        struct VolumeResponse: Decodable { let level: Int }
        guard let response = try? await scriptRunner.decodeJSONScript(
            VolumeResponse.self,
            script: YouTubeMusicJSScripts.fetchVolume,
            webView: webView
        ) else { return 0 }
        return response.level
    }

    // MARK: - 再生状態

    @MainActor
    func fetchIsPlaying(using webView: WKWebView) async -> Bool {
        struct IsPlayingResponse: Decodable { let isPlaying: Bool }
        guard let response = try? await scriptRunner.decodeJSONScript(
            IsPlayingResponse.self,
            script: YouTubeMusicJSScripts.fetchIsPlaying,
            webView: webView
        ) else { return false }
        return response.isPlaying
    }

    // MARK: - 現在のトラック

    @MainActor
    func fetchCurrentTrack(playlistName: String, using webView: WKWebView) async -> TrackInfo? {
        struct TrackResponse: Decodable {
            let videoId: String
            let title: String
            let artist: String
            let album: String
            let durationSeconds: Int
            let thumbnailURL: String?
        }
        guard let json = try? await scriptRunner.runJSONScript(
            YouTubeMusicJSScripts.fetchCurrentTrack,
            webView: webView
        ), json != "null",
              let data = json.data(using: .utf8),
              let response = try? JSONDecoder().decode(TrackResponse.self, from: data) else {
            return nil
        }
        guard !response.title.isEmpty else { return nil }
        return TrackInfo(
            name: response.title,
            artist: response.artist,
            album: response.album,
            durationSeconds: response.durationSeconds,
            playlistName: playlistName,
            serviceID: response.videoId,
            artworkURL: response.thumbnailURL
        )
    }

    // MARK: - 再生位置

    @MainActor
    func fetchPlaybackPosition(using webView: WKWebView) async -> Double {
        struct PositionResponse: Decodable { let positionSeconds: Double }
        guard let response = try? await scriptRunner.decodeJSONScript(
            PositionResponse.self,
            script: YouTubeMusicJSScripts.fetchPlaybackPosition,
            webView: webView
        ) else { return 0 }
        return response.positionSeconds
    }

    @MainActor
    func seekToPosition(_ seconds: Double, using webView: WKWebView) async {
        _ = try? await scriptRunner.runJSONScript(
            YouTubeMusicJSScripts.seekToPosition(seconds),
            webView: webView
        )
    }

    // MARK: - プライベートユーティリティ

    /// 目的の `videoId` に対応する再生対象が利用可能になるまで最大 `timeoutSeconds` 秒ポーリングする
    @MainActor
    private func waitForPlaybackTarget(videoId: String, webView: WKWebView, timeoutSeconds: Double) async throws {
        struct PlaybackTargetResponse: Decodable {
            let matchedVideoID: Bool
            let hasVideo: Bool
            let isReady: Bool
        }

        let checkScript = YouTubeMusicJSScripts.waitForPlaybackTarget(videoId: videoId)
        let intervalNS: UInt64 = 300_000_000 // 0.3 秒
        let maxIterations = Int(timeoutSeconds / 0.3)
        for _ in 0..<maxIterations {
            if let response = try? await scriptRunner.decodeJSONScript(
                PlaybackTargetResponse.self,
                script: checkScript,
                webView: webView
            ), response.matchedVideoID && response.hasVideo && response.isReady {
                return
            }
            try? await Task.sleep(nanoseconds: intervalNS)
        }
        throw YouTubeMusicScriptRunnerError.scriptFailed(String(localized: "タイムアウトしました。"))
    }
}
