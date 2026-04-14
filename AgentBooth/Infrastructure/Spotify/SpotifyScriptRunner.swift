import Foundation
import WebKit

/// Spotify WebView スクリプト実行エラー。
enum SpotifyScriptRunnerError: LocalizedError {
    case invalidResponse
    case scriptFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return String(localized: "レスポンスのパースに失敗しました。")
        case .scriptFailed(let message):
            return String(format: String(localized: "スクリプト実行に失敗しました: %@"), message)
        }
    }
}

/// Spotify DOM 操作用の JavaScript 実行ユーティリティ。
struct SpotifyScriptRunner {
    /// JSON 文字列を返すスクリプトを実行する。
    @MainActor
    func runJSONScript(_ script: String, webView: WKWebView) async throws -> String {
        let result = try await evaluateJavaScript(script, webView: webView)
        guard let jsonString = result as? String else {
            throw SpotifyScriptRunnerError.invalidResponse
        }
        if let errorMessage = extractErrorMessage(from: jsonString) {
            throw SpotifyScriptRunnerError.scriptFailed(errorMessage)
        }
        return jsonString
    }

    /// JSON 文字列を返すスクリプトを実行し Decodable 型にデコードする。
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

    /// 同期 JavaScript を実行して JSON 文字列を返す。
    @MainActor
    func runSynchronousJSONScript(_ script: String, webView: WKWebView) async throws -> String {
        let result = try await evaluateSynchronousJavaScript(script, webView: webView)
        guard let jsonString = result as? String else {
            throw SpotifyScriptRunnerError.invalidResponse
        }
        if let errorMessage = extractErrorMessage(from: jsonString) {
            throw SpotifyScriptRunnerError.scriptFailed(errorMessage)
        }
        return jsonString
    }

    /// 同期 JavaScript を実行し Decodable 型へデコードする。
    @MainActor
    func decodeSynchronousJSONScript<T: Decodable>(
        _ type: T.Type,
        script: String,
        webView: WKWebView,
        decoder: JSONDecoder = JSONDecoder()
    ) async throws -> T {
        let jsonString = try await runSynchronousJSONScript(script, webView: webView)
        let data = Data(jsonString.utf8)
        return try decoder.decode(T.self, from: data)
    }

    @MainActor
    private func evaluateJavaScript(_ script: String, webView: WKWebView) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { result in
                switch result {
                case .success(let value):
                    continuation.resume(returning: value)
                case .failure(let error):
                    continuation.resume(throwing: SpotifyScriptRunnerError.scriptFailed(error.localizedDescription))
                }
            }
        }
    }

    @MainActor
    private func evaluateSynchronousJavaScript(_ script: String, webView: WKWebView) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { value, error in
                if let error {
                    continuation.resume(throwing: SpotifyScriptRunnerError.scriptFailed(error.localizedDescription))
                    return
                }
                continuation.resume(returning: value ?? "null")
            }
        }
    }

    private func extractErrorMessage(from jsonString: String) -> String? {
        guard let data = jsonString.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object["__error"] as? String
    }
}
