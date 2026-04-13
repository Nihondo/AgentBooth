// MARK: - YouTubeMusicLoginViewModel.swift
// YouTube Music ログインウィンドウの状態を管理する ViewModel。
// WebViewStore のログイン状態を監視し、UI へ反映する。

import SwiftUI
import Combine
import WebKit

@MainActor
final class YouTubeMusicLoginViewModel: ObservableObject {
    @Published var isLoggedIn = false
    @Published var statusMessage = "YouTube Music にログインしてください。"

    private let store: YouTubeMusicWebViewStore
    private var cancellables = Set<AnyCancellable>()

    init(store: YouTubeMusicWebViewStore) {
        self.store = store
        bindStore()
    }

    var webViewStore: YouTubeMusicWebViewStore { store }

    /// ログアウト: キャッシュ・クッキーを全削除してリロード
    func logout() async {
        let dataStore = store.webView.configuration.websiteDataStore
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        await withCheckedContinuation { continuation in
            dataStore.removeData(ofTypes: dataTypes, modifiedSince: .distantPast) {
                continuation.resume()
            }
        }
        // 明示的なクッキー削除
        await withCheckedContinuation { continuation in
            dataStore.httpCookieStore.getAllCookies { cookies in
                for cookie in cookies {
                    dataStore.httpCookieStore.delete(cookie)
                }
                continuation.resume()
            }
        }
        store.reloadFromOrigin()
    }

    private func bindStore() {
        store.$isLoggedIn
            .receive(on: RunLoop.main)
            .assign(to: &$isLoggedIn)

        store.$isLoggedIn
            .receive(on: RunLoop.main)
            .map { $0 ? "ログイン済みです。ウィンドウを閉じてください。" : "YouTube Music にログインしてください。" }
            .assign(to: &$statusMessage)
    }
}
