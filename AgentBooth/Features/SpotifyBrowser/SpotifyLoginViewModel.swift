import Combine
import SwiftUI

/// Spotify ログインウィンドウの状態を管理する。
@MainActor
final class SpotifyLoginViewModel: ObservableObject {
    @Published var isLoggedIn = false
    @Published var statusMessage = String(localized: "Spotify にログインしてください。")

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
            .map { $0 ? String(localized: "ログイン済みです。ウィンドウを閉じてください。") : String(localized: "Spotify にログインしてください。") }
            .assign(to: &$statusMessage)
    }
}
