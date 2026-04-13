// MARK: - YouTubeMusicAPIFetcher.swift
// YouTube Music 内部 API からプレイリスト・トラック一覧を取得する。
// WebView 内 JS から fetch (credentials:"include") で YouTube Music の
// /youtubei/v1/browse エンドポイントを呼ぶ。AgentLimits の各 UsageFetcher と同パターン。

import Foundation
import WebKit

// MARK: - エラー型

enum YouTubeMusicAPIFetcherError: LocalizedError {
    case notLoggedIn
    case pageNotReady
    case scriptFailed(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "YouTube Music にログインしていません。設定から先にログインしてください。"
        case .pageNotReady:
            return "YouTube Music のページが読み込まれていません。"
        case .scriptFailed(let msg):
            return "取得に失敗しました: \(msg)"
        case .invalidResponse:
            return "レスポンスのパースに失敗しました。"
        }
    }
}

// MARK: - レスポンスモデル

/// プレイリスト 1 件
struct YouTubeMusicPlaylistItem: Codable {
    let id: String
    let title: String
}

/// トラック 1 件（JS 側から返される生データ）
struct YouTubeMusicTrackItem: Codable {
    let videoId: String
    let title: String
    let artist: String
    let album: String
    let durationSeconds: Int
    let thumbnailURL: String?
}

// MARK: - Fetcher

/// YouTube Music の内部 API を WebView 経由で叩くフェッチャー
final class YouTubeMusicAPIFetcher {
    private let scriptRunner: YouTubeMusicScriptRunner

    init(scriptRunner: YouTubeMusicScriptRunner = YouTubeMusicScriptRunner()) {
        self.scriptRunner = scriptRunner
    }

    // MARK: - プレイリスト

    /// ユーザーのプレイリスト一覧を取得する
    @MainActor
    func fetchPlaylists(using webView: WKWebView) async throws -> [YouTubeMusicPlaylistItem] {
        let dump = await debugDumpPlaylists(using: webView)
        print("🎵 [YTM] structure dump:", dump)
        do {
            return try await scriptRunner.decodeJSONScript(
                [YouTubeMusicPlaylistItem].self,
                script: YouTubeMusicJSScripts.fetchPlaylists,
                webView: webView
            )
        } catch let error as YouTubeMusicScriptRunnerError {
            throw mapError(error)
        } catch {
            throw YouTubeMusicAPIFetcherError.invalidResponse
        }
    }

    // MARK: - トラック

    /// 指定プレイリストのトラック一覧を取得する
    @MainActor
    func fetchTracks(
        playlistId: String,
        using webView: WKWebView
    ) async throws -> [YouTubeMusicTrackItem] {
        let dumpScript = YouTubeMusicJSScripts.debugDumpTracks(playlistId: playlistId)
        let dump = (try? await scriptRunner.runJSONScript(dumpScript, webView: webView)) ?? "nil"
        print("🎵 [YTM] tracks structure dump (playlistId=\(playlistId)):", dump)

        let script = YouTubeMusicJSScripts.fetchTracks(playlistId: playlistId)
        do {
            return try await scriptRunner.decodeJSONScript(
                [YouTubeMusicTrackItem].self,
                script: script,
                webView: webView
            )
        } catch let error as YouTubeMusicScriptRunnerError {
            throw mapError(error)
        } catch {
            throw YouTubeMusicAPIFetcherError.invalidResponse
        }
    }

    // MARK: - デバッグ

    /// プレイリストAPIのレスポンス構造を文字列で返す（デバッグ用）
    @MainActor
    func debugDumpPlaylists(using webView: WKWebView) async -> String {
        (try? await scriptRunner.runJSONScript(
            YouTubeMusicJSScripts.debugDumpPlaylists,
            webView: webView
        )) ?? "nil"
    }

    // MARK: - 変換ヘルパー

    private func mapError(_ error: YouTubeMusicScriptRunnerError) -> YouTubeMusicAPIFetcherError {
        switch error {
        case .invalidResponse:
            return .invalidResponse
        case .scriptFailed(let msg):
            if msg.lowercased().contains("not found") || msg.lowercased().contains("login") {
                return .notLoggedIn
            }
            return .scriptFailed(msg)
        }
    }
}
