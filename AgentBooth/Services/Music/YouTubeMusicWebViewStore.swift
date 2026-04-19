// MARK: - YouTubeMusicWebViewStore.swift
// YouTube Music 用 WKWebView のライフサイクルを管理する。
//
// 2つの WebView を管理:
//   playbackWebView: 再生専用。常時オフスクリーンウィンドウに配置し audio を有効化。
//   webView (loginWebView): ログイン UI 用。ブラウザウィンドウで表示。
// 両者は WKWebsiteDataStore.default() を共有するためクッキーは自動同期。

import AppKit
import Combine
import SwiftUI
import WebKit

private enum YouTubeCookieSpec {
    static let name = "__Secure-3PSID"
    static let domain = ".youtube.com"
}

let defaultYouTubeMusicUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.4 Safari/605.1.15"

// MARK: - WebView Store

@MainActor
final class YouTubeMusicWebViewStore: ObservableObject {
    static let targetHost = "music.youtube.com"
    static let musicURL = URL(string: "https://music.youtube.com")!

    /// ログイン UI 用 WebView（ブラウザウィンドウで表示）
    let webView: WKWebView
    /// 再生専用 WebView（常時オフスクリーンウィンドウに配置）
    let playbackWebView: WKWebView

    @Published var isLoggedIn = false
    @Published var isPageReady = false
    @Published var popupWebView: WKWebView?
    var onPopupNavigationFinished: ((WKWebView) async -> Bool)?

    private var loginCoordinator: WebViewCoordinator?
    private let cookieStore: WKHTTPCookieStore
    private var cookieObserver: CookieObserver?
    private var isClosingPopup = false
    /// playbackWebView を保持するオフスクリーンウィンドウ
    private var offscreenWindowHost: OffscreenPlaybackWindowHost?

    init() {
        let dataStore = WKWebsiteDataStore.default()
        let cookieStore = dataStore.httpCookieStore
        self.cookieStore = cookieStore

        // ── ログイン用 WebView ──
        let loginConfig = WKWebViewConfiguration()
        loginConfig.websiteDataStore = dataStore
        loginConfig.preferences.javaScriptCanOpenWindowsAutomatically = true
        let login = WKWebView(frame: .zero, configuration: loginConfig)
        self.webView = login

        // ── 再生用 WebView（オートプレイ許可）──
        let playConfig = WKWebViewConfiguration()
        playConfig.websiteDataStore = dataStore
        playConfig.mediaTypesRequiringUserActionForPlayback = []
        let play = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 1280, height: 720),
            configuration: playConfig
        )
        self.playbackWebView = play

        // ログイン WebView の delegate 設定
        let coord = WebViewCoordinator(store: self)
        self.loginCoordinator = coord
        login.navigationDelegate = coord
        login.uiDelegate = coord

        // Cookie 監視
        let observer = CookieObserver(store: self)
        self.cookieObserver = observer
        cookieStore.add(observer)

        // 初期ロード
        login.load(URLRequest(url: Self.musicURL))
        play.load(URLRequest(url: Self.musicURL))

        // メインウィンドウ表示後にオフスクリーンウィンドウを設定する
        // 1ループ遅延だけでは SwiftUI がメインウィンドウを orderFront する前に実行される場合があるため
        // 短い遅延を設けて確実にメインウィンドウが前面に表示されてから設定する
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
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

    // MARK: - オフスクリーンウィンドウ

    /// playbackWebView をウィンドウ階層に入れて audio 再生を常時有効化する
    private func setupOffscreenWindow() {
        offscreenWindowHost = OffscreenPlaybackWindowHost(
            contentView: playbackWebView,
            frame: NSRect(x: -10000, y: -10000, width: 1280, height: 720)
        )
    }

    // MARK: - ログイン UI

    /// 両 WebView のユーザーエージェントを変更する。空文字列を渡すと UA をリセット（WKWebView デフォルトに戻る）。
    func setUserAgent(_ ua: String) {
        let value = ua.isEmpty ? nil : ua
        webView.customUserAgent = value
        playbackWebView.customUserAgent = value
    }

    func reloadFromOrigin() {
        isPageReady = false
        webView.load(URLRequest(
            url: Self.musicURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 60
        ))
    }

    func closePopupWebView() {
        guard !isClosingPopup else { return }
        isClosingPopup = true
        popupWebView?.stopLoading()
        popupWebView = nil
        onPopupNavigationFinished = nil
        isClosingPopup = false
    }

    // MARK: - ログイン状態

    func refreshLoginStatus() async {
        isLoggedIn = await hasValidSessionCookie()
    }

    func hasValidSessionCookie() async -> Bool {
        await withCheckedContinuation { continuation in
            cookieStore.getAllCookies { cookies in
                let now = Date()
                let isValid = cookies.contains { cookie in
                    guard cookie.name == YouTubeCookieSpec.name else { return false }
                    guard cookie.domain.hasSuffix(YouTubeCookieSpec.domain) else { return false }
                    if let exp = cookie.expiresDate { return exp > now }
                    return true
                }
                continuation.resume(returning: isValid)
            }
        }
    }

    // MARK: - Cookie Observer

    private final class CookieObserver: NSObject, WKHTTPCookieStoreObserver {
        private weak var store: YouTubeMusicWebViewStore?
        init(store: YouTubeMusicWebViewStore) { self.store = store }
        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            Task { @MainActor in await store?.refreshLoginStatus() }
        }
    }
}

// MARK: - Navigation Coordinator（ログイン WebView 用）

private final class WebViewCoordinator: NSObject, WKNavigationDelegate {
    private weak var store: YouTubeMusicWebViewStore?
    init(store: YouTubeMusicWebViewStore) { self.store = store }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard webView === store?.webView else { return }
        store?.isPageReady = false
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let store else { return }
        if webView === store.webView {
            store.isPageReady = webView.url?.host == YouTubeMusicWebViewStore.targetHost
            Task { await store.refreshLoginStatus() }
        } else if webView === store.popupWebView {
            Task {
                if let cb = store.onPopupNavigationFinished, await cb(webView) {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    store.closePopupWebView()
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard webView === store?.webView else { return }
        store?.isPageReady = false
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard webView === store?.webView else { return }
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
        if webView === store.popupWebView { store.closePopupWebView() }
    }
}

// MARK: - SwiftUI 統合（ログイン UI 用）

struct YouTubeMusicWebViewRepresentable: NSViewRepresentable {
    @ObservedObject var store: YouTubeMusicWebViewStore
    func makeNSView(context: Context) -> WKWebView { store.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

/// オフスクリーン再生用のウィンドウを保持する。
@MainActor
final class OffscreenPlaybackWindowHost {
    private let window: NSWindow

    init(contentView: NSView, frame: NSRect) {
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .init(rawValue: NSWindow.Level.normal.rawValue - 1)
        window.collectionBehavior = [.transient, .ignoresCycle, .canJoinAllSpaces]
        window.contentView = contentView
        window.orderBack(nil)
        self.window = window
    }
}
