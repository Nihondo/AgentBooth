import AppKit
import SwiftUI
import WebKit

let defaultSpotifyUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.4 Safari/605.1.15"

/// Spotify 用 WKWebView のライフサイクルを管理する。
@MainActor
final class SpotifyWebViewStore: ObservableObject {
    static let targetHost = "open.spotify.com"
    static let musicURL = URL(string: "https://open.spotify.com")!
    static let libraryURL = URL(string: "https://open.spotify.com/collection/playlists")!

    let webView: WKWebView
    let playbackWebView: WKWebView

    @Published var isLoggedIn = false
    @Published var isPageReady = false
    @Published var currentURL: URL?
    @Published var popupWebView: WKWebView?
    var onPopupNavigationFinished: ((WKWebView) async -> Bool)?

    private let dataStore: WKWebsiteDataStore
    private let cookieStore: WKHTTPCookieStore
    private var coordinator: WebViewCoordinator?
    private var cookieObserver: CookieObserver?
    private var isClosingPopup = false
    private var offscreenWindow: NSWindow?

    /// WebView 群を生成し Spotify Web Player を初期ロードする。
    init() {
        let dataStore = WKWebsiteDataStore.default()
        self.dataStore = dataStore
        self.cookieStore = dataStore.httpCookieStore

        let loginConfig = WKWebViewConfiguration()
        loginConfig.websiteDataStore = dataStore
        loginConfig.preferences.javaScriptCanOpenWindowsAutomatically = true
        let login = WKWebView(frame: .zero, configuration: loginConfig)
        login.customUserAgent = defaultSpotifyUserAgent
        self.webView = login

        let playbackConfig = WKWebViewConfiguration()
        playbackConfig.websiteDataStore = dataStore
        playbackConfig.mediaTypesRequiringUserActionForPlayback = []
        let playback = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 1280, height: 720),
            configuration: playbackConfig
        )
        playback.customUserAgent = defaultSpotifyUserAgent
        self.playbackWebView = playback

        let coordinator = WebViewCoordinator(store: self)
        self.coordinator = coordinator
        login.navigationDelegate = coordinator
        login.uiDelegate = coordinator
        playback.navigationDelegate = coordinator
        playback.uiDelegate = coordinator

        let observer = CookieObserver(store: self)
        self.cookieObserver = observer
        cookieStore.add(observer)

        login.load(URLRequest(url: Self.musicURL))
        playback.load(URLRequest(url: Self.libraryURL))

        DispatchQueue.main.async { [weak self] in
            self?.setupOffscreenWindow()
        }
    }

    deinit {
        if let observer = cookieObserver {
            MainActor.assumeIsolated {
                cookieStore.remove(observer)
            }
        }
    }

    /// playbackWebView をオフスクリーンウィンドウに保持する。
    private func setupOffscreenWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 1280, height: 720),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .init(rawValue: NSWindow.Level.normal.rawValue - 1)
        window.collectionBehavior = [.transient, .ignoresCycle, .canJoinAllSpaces]
        window.contentView = playbackWebView
        window.orderBack(nil)
        offscreenWindow = window
    }

    /// 表示用 WebView を再読み込みする。
    func reloadFromOrigin() {
        isPageReady = false
        webView.load(URLRequest(
            url: Self.musicURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 60
        ))
    }

    /// 両 WebView の User Agent を変更する。
    func setUserAgent(_ userAgent: String) {
        let value = userAgent.isEmpty ? nil : userAgent
        webView.customUserAgent = value
        playbackWebView.customUserAgent = value
    }

    /// ポップアップ WebView を閉じる。
    func closePopupWebView() {
        guard !isClosingPopup else { return }
        isClosingPopup = true
        popupWebView?.stopLoading()
        popupWebView = nil
        onPopupNavigationFinished = nil
        isClosingPopup = false
    }

    /// Spotify セッションだけを削除して再読み込みする。
    func clearSessionData() async {
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            dataStore.fetchDataRecords(ofTypes: dataTypes) { records in
                let spotifyRecords = records.filter { $0.displayName.localizedCaseInsensitiveContains("spotify") }
                self.dataStore.removeData(ofTypes: dataTypes, for: spotifyRecords) {
                    continuation.resume()
                }
            }
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            cookieStore.getAllCookies { cookies in
                let spotifyCookies = cookies.filter { $0.domain.localizedCaseInsensitiveContains("spotify.com") }
                guard !spotifyCookies.isEmpty else {
                    continuation.resume()
                    return
                }
                let group = DispatchGroup()
                for cookie in spotifyCookies {
                    group.enter()
                    self.cookieStore.delete(cookie) {
                        group.leave()
                    }
                }
                group.notify(queue: .main) {
                    continuation.resume()
                }
            }
        }

        reloadFromOrigin()
        playbackWebView.load(URLRequest(
            url: Self.libraryURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 60
        ))
        await refreshLoginStatus()
    }

    /// ログイン状態を DOM から更新する。
    func refreshLoginStatus() async {
        currentURL = playbackWebView.url ?? webView.url
        let loginWebViewState = await evaluateLoginState(on: webView)
        let playbackWebViewState = await evaluateLoginState(on: playbackWebView)
        isLoggedIn = loginWebViewState || playbackWebViewState
        isPageReady = (playbackWebView.url?.host == Self.targetHost) || (webView.url?.host == Self.targetHost)
    }

    private func evaluateLoginState(on webView: WKWebView) async -> Bool {
        guard webView.url?.host == Self.targetHost else { return false }
        let runner = SpotifyScriptRunner()
        struct LoginStateResponse: Decodable {
            let isLoggedIn: Bool
            let currentURL: String
        }
        guard let response = try? await runner.decodeJSONScript(
            LoginStateResponse.self,
            script: SpotifyDOMScripts.detectLoginState,
            webView: webView
        ) else {
            return false
        }
        if let url = URL(string: response.currentURL) {
            currentURL = url
        }
        return response.isLoggedIn
    }

    private final class CookieObserver: NSObject, WKHTTPCookieStoreObserver {
        private weak var store: SpotifyWebViewStore?

        init(store: SpotifyWebViewStore) {
            self.store = store
        }

        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            Task { @MainActor in
                await store?.refreshLoginStatus()
            }
        }
    }
}

private final class WebViewCoordinator: NSObject, WKNavigationDelegate {
    private weak var store: SpotifyWebViewStore?

    init(store: SpotifyWebViewStore) {
        self.store = store
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard let store else { return }
        if webView === store.webView || webView === store.playbackWebView {
            store.isPageReady = false
            store.currentURL = webView.url
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let store else { return }
        if webView === store.webView || webView === store.playbackWebView {
            store.currentURL = webView.url
            store.isPageReady = webView.url?.host == SpotifyWebViewStore.targetHost
            Task { await store.refreshLoginStatus() }
        } else if webView === store.popupWebView {
            Task {
                if let callback = store.onPopupNavigationFinished, await callback(webView) {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    store.closePopupWebView()
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard webView === store?.webView || webView === store?.playbackWebView else { return }
        store?.isPageReady = false
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard webView === store?.webView || webView === store?.playbackWebView else { return }
        store?.isPageReady = false
    }
}

extension WebViewCoordinator: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let store else { return nil }
        guard navigationAction.targetFrame == nil else { return nil }
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let popup = WKWebView(frame: .zero, configuration: configuration)
        popup.navigationDelegate = self
        popup.uiDelegate = self
        store.popupWebView = popup
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard let store else { return }
        if webView === store.popupWebView {
            store.closePopupWebView()
        }
    }
}

/// Spotify のログイン用 WKWebView を SwiftUI に埋め込む。
struct SpotifyWebViewRepresentable: NSViewRepresentable {
    @ObservedObject var store: SpotifyWebViewStore

    func makeNSView(context: Context) -> WKWebView {
        store.webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
