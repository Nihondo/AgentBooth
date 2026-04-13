import Combine
import SwiftUI

/// Spotify ログインウィンドウの状態を管理する。
@MainActor
final class SpotifyLoginViewModel: ObservableObject {
    @Published var isLoggedIn = false
    @Published var statusMessage = "Spotify にログインしてください。"

    private let store: SpotifyWebViewStore
    private var cancellables = Set<AnyCancellable>()

    /// Spotify WebViewStore をバインドする。
    init(store: SpotifyWebViewStore) {
        self.store = store
        bindStore()
    }

    var webViewStore: SpotifyWebViewStore { store }

    /// Spotify のセッションを削除してログアウトする。
    func logout() async {
        await store.clearSessionData()
    }

    private func bindStore() {
        store.$isLoggedIn
            .receive(on: RunLoop.main)
            .assign(to: &$isLoggedIn)

        store.$isLoggedIn
            .receive(on: RunLoop.main)
            .map { $0 ? "ログイン済みです。ウィンドウを閉じてください。" : "Spotify にログインしてください。" }
            .assign(to: &$statusMessage)
    }
}
