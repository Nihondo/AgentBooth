// MARK: - YouTubeMusicScriptRunner.swift
// WKWebView で JavaScript を実行し JSON レスポンスをデコードするユーティリティ。
// AgentLimits の WebViewScriptRunner と同等の実装。

import Foundation
import WebKit

/// WebView スクリプト実行エラー
enum YouTubeMusicScriptRunnerError: LocalizedError {
    case invalidResponse
    case scriptFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "レスポンスのパースに失敗しました。"
        case .scriptFailed(let message):
            return "スクリプト実行に失敗しました: \(message)"
        }
    }
}

/// JavaScript を WKWebView で実行し JSON デコードを補助するユーティリティ
struct YouTubeMusicScriptRunner {
    /// JSON 文字列を返すスクリプトを実行する
    @MainActor
    func runJSONScript(_ script: String, webView: WKWebView) async throws -> String {
        let result = try await evaluateJavaScript(script, webView: webView)
        guard let jsonString = result as? String else {
            throw YouTubeMusicScriptRunnerError.invalidResponse
        }
        if let errorMessage = extractErrorMessage(from: jsonString) {
            throw YouTubeMusicScriptRunnerError.scriptFailed(errorMessage)
        }
        return jsonString
    }

    /// JSON 文字列を返すスクリプトを実行し Decodable 型にデコードする
    @MainActor
    func decodeJSONScript<T: Decodable>(
        _ type: T.Type,
        script: String,
        webView: WKWebView,
        decoder: JSONDecoder = JSONDecoder()
    ) async throws -> T {
        let jsonString = try await runJSONScript(script, webView: webView)
        let data = Data(jsonString.utf8)
        return try decoder.decode(T.self, from: data)
    }

    @MainActor
    private func evaluateJavaScript(_ script: String, webView: WKWebView) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { result in
                switch result {
                case .success(let value):
                    continuation.resume(returning: value ?? "null")
                case .failure(let error):
                    continuation.resume(throwing: YouTubeMusicScriptRunnerError.scriptFailed(error.localizedDescription))
                }
            }
        }
    }

    /// JSON 内の `__error` キーを抽出する
    private func extractErrorMessage(from jsonString: String) -> String? {
        guard let data = jsonString.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object["__error"] as? String
    }
}
